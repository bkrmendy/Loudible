import Foundation
import Testing
import LoudibleCore
import LoudiblePresentation
import TestSupport

@MainActor
@Suite struct ExportViewModelTests {
    let api = MockAudibleAPI()
    let store = InMemoryCredentialStore(Fixtures.session())
    let converter = MockConverter()
    let downloader = MockDownloader()
    let work: TemporaryDirectory
    let downloads: LocalDownloads

    init() throws {
        work = try TemporaryDirectory("vm-work")
        downloads = LocalDownloads(
            folder: work.url.appendingPathComponent("Downloads", isDirectory: true),
            manifestFolder: work.url.appendingPathComponent("Manifests", isDirectory: true),
            trash: { try FileManager.default.removeItem(at: $0) }
        )
        api.licenseHandler.withLock { $0 = { asin, _ in Fixtures.license(asin: asin) } }
        api.libraryHandler.withLock {
            $0 = { _, _, marketplace, _ in LibraryPage(entries: marketplace == .us ? [Fixtures.entry("B1"), Fixtures.entry("B2")] : []) }
        }
    }

    func makeApp() async throws -> (AppViewModel, ExportQueue) {
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        let queue = ExportQueue(auth: auth, api: api, downloader: downloader, converter: converter, downloads: downloads, maximumConcurrentBooks: 1)
        let app = AppViewModel(
            session: SessionViewModel(auth: auth),
            library: LibraryViewModel(service: LibraryService(api: api, auth: auth)),
            export: ExportViewModel(queue: queue, exportFolder: downloads.folder),
            downloads: downloads
        )
        await app.start()
        return (app, queue)
    }

    @Test func signedInStartLoadsLibrary() async throws {
        defer { work.cleanUp() }
        let (app, _) = try await makeApp()
        #expect(app.session.isSignedIn)
        #expect(app.library.books.map(\.asin) == ["B1", "B2"])
    }

    /// Exports both library books, one after the other.
    func exportAll(_ app: AppViewModel) async {
        for book in app.library.books { await app.export.exportOne(book) }
    }

    @Test func exportsIntoTheDownloadsFolder() async throws {
        defer { work.cleanUp() }
        let gate = AsyncGate()
        converter.handler.withLock { $0 = { request in await gate.wait(); try Data().write(to: request.output) } }
        let (app, queue) = try await makeApp()
        await exportAll(app)

        try await waitUntil { await app.export.isRunning }
        await gate.open()
        await queue.waitUntilFinished()
        try await waitUntil { await app.exportedFiles.count == 2 }
        #expect(!app.export.isRunning)
        #expect(app.exportedFiles.values.allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL == downloads.folder.standardizedFileURL
        })
        // The M4B files are not mistaken for downloads.
        #expect(app.downloadedFiles.keys.sorted() == ["B1", "B2"])
    }

    @Test func cancelRemovesAllBooks() async throws {
        defer { work.cleanUp() }
        let gate = AsyncGate()
        converter.handler.withLock { $0 = { request in await gate.wait(); try Task.checkCancellation(); try Data().write(to: request.output) } }
        let (app, queue) = try await makeApp()
        await exportAll(app)
        try await waitUntil { converter.requests.current.count == 1 }
        let cancelling = Task { await app.export.cancel() }
        await gate.open()
        await cancelling.value
        await queue.waitUntilFinished()
        #expect(!app.export.isRunning)
        #expect(app.export.jobs.isEmpty)
    }

    @Test func cancellingOneBookKeepsExportingTheOthers() async throws {
        defer { work.cleanUp() }
        let gate = AsyncGate()
        converter.handler.withLock {
            $0 = { request in
                if request.metadata.asin == "B1" { await gate.wait(); try Task.checkCancellation() }
                try Data().write(to: request.output)
            }
        }
        let (app, queue) = try await makeApp()
        await exportAll(app)
        try await waitUntil { converter.requests.current.count == 1 }
        let first = try #require(app.export.jobs.first)
        await app.export.cancel(jobID: first.id)
        await gate.open()
        await queue.waitUntilFinished()
        try await waitUntil { await !app.export.isRunning }
        #expect(app.export.jobs.first?.state == .cancelled)
        try await waitUntil { await app.exportedFiles.keys.sorted() == ["B2"] }
    }

    @Test func unavailableFolderIsReported() async throws {
        defer { work.cleanUp() }
        // A file where the downloads folder should be.
        try Data().write(to: downloads.folder)
        let (app, _) = try await makeApp()
        await app.export.exportOne(app.library.books[0])
        #expect(app.export.errorMessage?.contains("not writable") == true)
        #expect(!app.export.isRunning)
    }

    @Test func signInAgainResumesPausedExport() async throws {
        defer { work.cleanUp() }
        let renewed = Locked(false)
        api.licenseHandler.withLock {
            $0 = { asin, session in
                guard session.accessToken == "fresh" else { throw ExporterError.authenticationRequired }
                return Fixtures.license(asin: asin)
            }
        }
        api.refreshHandler.withLock { $0 = { _ in throw ExporterError.authenticationRequired } }
        api.registerHandler.withLock { $0 = { _, _ in renewed.withLock { $0 = true }; return Fixtures.session(accessToken: "fresh") } }
        let (app, queue) = try await makeApp()
        await app.export.exportOne(app.library.books[0])

        try await waitUntil { await app.export.isWaitingForAuthentication }
        try await waitUntil { await app.session.needsReauthentication }
        #expect(app.export.notice == "Paused: sign in to Audible to continue.")
        #expect(app.library.books.count == 2) // rows stay while re-authenticating

        await app.session.signIn()
        await app.session.completeSignIn(with: Fixtures.callbackURL())
        await queue.waitUntilFinished()
        try await waitUntil { await !app.export.isRunning }
        #expect(app.export.notice == nil)
        try await waitUntil { await app.exportedFiles.keys.sorted() == ["B1"] }
    }

    @Test func signOutClearsLibrary() async throws {
        defer { work.cleanUp() }
        let (app, _) = try await makeApp()
        app.library.toggleSelection("B1")
        await app.session.signOut()
        try await waitUntil { await app.library.books.isEmpty }
        #expect(app.library.selection.isEmpty)
        #expect(!app.library.canRefresh)
    }

    // MARK: Downloads

    /// A download as an earlier run left it: the audio file and its manifest.
    func keepDownload(_ book: Audiobook) throws {
        try downloads.ensureFolder()
        try Data("enc".utf8).write(to: downloads.folder.appendingPathComponent("\(book.title) [\(book.asin)].aaxc"))
        try downloads.writeManifest(DownloadManifest(book: book, decryption: Fixtures.license(asin: book.asin).decryption, chapters: [], downloadedAt: Fixtures.referenceDate))
    }

    @Test func downloadedBooksThatLeftTheLibraryStayVisible() async throws {
        defer { work.cleanUp() }
        try keepDownload(Fixtures.book("B1", title: "Book B1"))
        try keepDownload(Fixtures.book("GONE", title: "Returned"))
        let (app, _) = try await makeApp()

        #expect(app.library.books.map(\.asin) == ["B1", "B2", "GONE"])
        #expect(app.library.isInLibrary("B1"))
        #expect(!app.library.isInLibrary("GONE"))
        #expect(app.status(for: Fixtures.book("B1")) == .downloaded)
        #expect(app.status(for: Fixtures.book("B2")) == .none)
        app.library.searchText = "returned"
        #expect(app.library.visibleBooks.map(\.asin) == ["GONE"])
    }

    @Test func rescanDropsDeletedFilesAndTheirManifests() async throws {
        defer { work.cleanUp() }
        try keepDownload(Fixtures.book("GONE", title: "Returned"))
        let (app, _) = try await makeApp()
        #expect(app.library.books.map(\.asin) == ["B1", "B2", "GONE"])

        try FileManager.default.removeItem(at: downloads.folder.appendingPathComponent("Returned [GONE].aaxc"))
        await app.rescan()
        #expect(app.library.books.map(\.asin) == ["B1", "B2"])
        #expect(downloads.manifest(for: "GONE") == nil)
    }

    @Test func downloadFromMenuUpdatesStatusAndMenu() async throws {
        defer { work.cleanUp() }
        let gate = AsyncGate()
        downloader.handler.withLock { $0 = { _, destination in await gate.wait(); try Data().write(to: destination) } }
        let (app, queue) = try await makeApp()
        let book = app.library.books[0]
        #expect(app.menuItems(for: book).map(\.action) == [.download, .export])

        await app.perform(.download, on: book)
        try await waitUntil { await app.status(for: book) == .running(
            .download, progress: 0.5 * 0.96 + 0.02, transferred: TransferProgress(bytesReceived: 50, bytesExpected: 100)
        ) }
        guard case .cancel(_, .download) = app.menuItems(for: book).first?.action else {
            Issue.record("expected Cancel Download"); return
        }

        await gate.open()
        await queue.waitUntilFinished()
        // Finishing a job triggers a rescan.
        try await waitUntil { await app.status(for: book) == .downloaded }
        #expect(app.menuItems(for: book).map(\.action) == [.export, .showDownload, .deleteDownload])
    }

    @Test func selectionButtonsActOnBooksThatOfferTheAction() async throws {
        defer { work.cleanUp() }
        try keepDownload(Fixtures.book("B1", title: "Book B1"))
        let (app, queue) = try await makeApp()
        let (downloaded, notDownloaded) = (app.library.books[0], app.library.books[1])
        app.library.setSelection(["B1", "B2"])
        #expect(app.selectedBooks(offering: .download) == [notDownloaded])
        #expect(app.selectedBooks(offering: .export) == [downloaded, notDownloaded])

        await app.performOnSelection(.export)
        #expect(app.library.selection.isEmpty)
        await queue.waitUntilFinished()
        try await waitUntil { await app.status(for: downloaded) == .exported }
        try await waitUntil { await app.status(for: notDownloaded) == .exported }
        // Exporting a book that was not downloaded keeps the download.
        #expect(app.downloadedFiles["B2"] != nil)
    }

    @Test func downloadAndExportRunTogether() async throws {
        defer { work.cleanUp() }
        let gate = AsyncGate()
        downloader.handler.withLock { $0 = { _, destination in await gate.wait(); try Data().write(to: destination) } }
        let (app, queue) = try await makeApp()
        await app.export.download([app.library.books[0]])
        await app.export.exportOne(app.library.books[1])
        #expect(app.export.activeJobCount == 2)
        await gate.open()
        await queue.waitUntilFinished()
        try await waitUntil { await !app.export.isRunning }
        try await waitUntil { await app.status(for: app.library.books[0]) == .downloaded }
        try await waitUntil { await app.status(for: app.library.books[1]) == .exported }
    }

    @Test func failureStaysUntilTheNextAttempt() async throws {
        defer { work.cleanUp() }
        api.licenseHandler.withLock { $0 = { asin, _ in throw ExporterError.licenseDenied(asin: asin, reason: "not owned") } }
        let (app, queue) = try await makeApp()
        let book = app.library.books[0]
        await app.export.download([book])
        await queue.waitUntilFinished()
        try await waitUntil { await app.status(for: book) == .failed(.download, "The download license was denied: not owned") }

        // Another book's run drops the finished job from the queue; the failure stays.
        await app.export.download([app.library.books[1]])
        await queue.waitUntilFinished()
        try await waitUntil { await !app.export.isRunning }
        #expect(app.status(for: book) == .failed(.download, "The download license was denied: not owned"))
        // Download doubles as Retry.
        #expect(app.menuItems(for: book).map(\.action) == [.download, .export])

        api.licenseHandler.withLock { $0 = { asin, _ in Fixtures.license(asin: asin) } }
        await app.export.download([book])
        await queue.waitUntilFinished()
        try await waitUntil { await app.status(for: book) == .downloaded }
    }

    @Test func deleteDownloadKeepsTheExport() async throws {
        defer { work.cleanUp() }
        try keepDownload(Fixtures.book("B1", title: "Book B1"))
        try Data("m4b".utf8).write(to: downloads.folder.appendingPathComponent("Book B1 [B1].m4b"))
        let (app, _) = try await makeApp()
        #expect(app.status(for: app.library.books[0]) == .exported)

        await app.deleteDownload(app.library.books[0])
        #expect(app.downloadedFiles["B1"] == nil)
        #expect(app.exportedFiles["B1"] != nil)
        #expect(downloads.manifest(for: "B1") == nil)
        #expect(app.menuItems(for: app.library.books[0]).map(\.action) == [.download, .export, .showExport])
    }

    @Test func signOutCancelsJobsAndKeepsFinishedFiles() async throws {
        defer { work.cleanUp() }
        downloader.handler.withLock {
            $0 = { source, destination in
                // B2 only ends by being cancelled.
                if source.lastPathComponent.hasPrefix("B2") { try await Task.sleep(for: .seconds(60)) }
                try Data().write(to: destination)
            }
        }
        let (app, queue) = try await makeApp()
        await app.export.download(app.library.books)
        try await waitUntil { downloader.downloads.current.count == 2 }
        #expect(app.hasActiveJobs)
        await app.signOut()
        await queue.waitUntilFinished()
        #expect(!app.hasActiveJobs)
        #expect(!app.session.isSignedIn)
        #expect(downloads.scanDownloads().keys.sorted() == ["B1"])
        try await waitUntil { await app.library.books.isEmpty }
    }
}
