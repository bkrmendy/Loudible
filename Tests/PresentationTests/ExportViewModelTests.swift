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
    let destination: TemporaryDirectory
    let work: TemporaryDirectory
    let downloads: LocalDownloads

    init() throws {
        destination = try TemporaryDirectory("vm-destination")
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
            export: ExportViewModel(queue: queue),
            downloads: downloads
        )
        await app.start()
        return (app, queue)
    }

    @Test func signedInStartLoadsLibrary() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
        let (app, _) = try await makeApp()
        #expect(app.session.isSignedIn)
        #expect(app.library.books.map(\.asin) == ["B1", "B2"])
    }

    @Test func exportRequiresSelectionFolderAndSignIn() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
        let (app, _) = try await makeApp()
        #expect(!app.canExport)
        app.library.toggleSelection("B1")
        #expect(!app.canExport)
        app.export.destinationFolder = destination.url
        #expect(app.canExport)
        #expect(!app.export.canExport(app.library.selectedBooks, isSignedIn: false))
    }

    @Test func runsExportAndReportsProgress() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
        let gate = AsyncGate()
        converter.handler.withLock { $0 = { request in await gate.wait(); try Data().write(to: request.output) } }
        let (app, queue) = try await makeApp()
        app.library.setSelection(["B1", "B2"])
        app.export.destinationFolder = destination.url
        await app.exportSelection()

        try await waitUntil { await app.export.isRunning }
        #expect(app.export.canCancel)
        #expect(!app.export.canChooseFolder)
        #expect(!app.canExport)
        #expect(app.export.statusText == "Exporting 1 of 2…")

        await gate.open()
        await queue.waitUntilFinished()
        try await waitUntil { await !app.export.isRunning }
        #expect(app.export.fractionCompleted == 1)
        #expect(app.export.statusText == "2 exported")
        #expect(app.canExport)
    }

    @Test func cancelRemovesAllBooks() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
        let gate = AsyncGate()
        converter.handler.withLock { $0 = { request in await gate.wait(); try Task.checkCancellation(); try Data().write(to: request.output) } }
        let (app, queue) = try await makeApp()
        app.library.setSelection(["B1", "B2"])
        app.export.destinationFolder = destination.url
        await app.exportSelection()
        try await waitUntil { converter.requests.current.count == 1 }
        let cancelling = Task { await app.export.cancel() }
        await gate.open()
        await cancelling.value
        await queue.waitUntilFinished()
        #expect(!app.export.isRunning)
        #expect(app.export.jobs.isEmpty)
        #expect(app.export.statusText == nil)
        #expect(app.canExport)
    }

    @Test func cancellingOneBookKeepsExportingTheOthers() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
        let gate = AsyncGate()
        converter.handler.withLock {
            $0 = { request in
                if request.metadata.asin == "B1" { await gate.wait(); try Task.checkCancellation() }
                try Data().write(to: request.output)
            }
        }
        let (app, queue) = try await makeApp()
        app.library.setSelection(["B1", "B2"])
        app.export.destinationFolder = destination.url
        await app.exportSelection()
        try await waitUntil { converter.requests.current.count == 1 }
        let first = try #require(app.export.jobs.first)
        #expect(app.export.canCancel(first))
        await app.export.cancel(first)
        await gate.open()
        await queue.waitUntilFinished()
        try await waitUntil { await !app.export.isRunning }
        #expect(app.export.statusText == "1 exported, 1 cancelled")
        #expect(!app.export.canCancel(app.export.jobs[1]))
    }

    @Test func unavailableFolderIsReported() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
        let (app, _) = try await makeApp()
        app.library.setSelection(["B1"])
        app.export.destinationFolder = destination.url.appendingPathComponent("gone")
        await app.exportSelection()
        #expect(app.export.errorMessage?.contains("not available") == true)
        #expect(!app.export.isRunning)
    }

    @Test func signInAgainResumesPausedExport() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
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
        app.library.setSelection(["B1"])
        app.export.destinationFolder = destination.url
        await app.exportSelection()

        try await waitUntil { await app.export.isWaitingForAuthentication }
        try await waitUntil { await app.session.needsReauthentication }
        #expect(app.export.statusText == "Paused: sign in to Audible to continue.")
        #expect(app.library.books.count == 2) // rows stay while re-authenticating

        await app.session.signIn()
        await app.session.completeSignIn(with: Fixtures.callbackURL())
        await queue.waitUntilFinished()
        try await waitUntil { await !app.export.isRunning }
        #expect(app.export.statusText == "1 exported")
    }

    @Test func signOutClearsLibrary() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
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
        defer { destination.cleanUp(); work.cleanUp() }
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

        // Selected, it is still left out of the toolbar export.
        app.export.destinationFolder = destination.url
        app.library.setSelection(["GONE"])
        #expect(!app.canExport)
    }

    @Test func rescanDropsDeletedFilesAndTheirManifests() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
        try keepDownload(Fixtures.book("GONE", title: "Returned"))
        let (app, _) = try await makeApp()
        #expect(app.library.books.map(\.asin) == ["B1", "B2", "GONE"])

        try FileManager.default.removeItem(at: downloads.folder.appendingPathComponent("Returned [GONE].aaxc"))
        await app.rescan()
        #expect(app.library.books.map(\.asin) == ["B1", "B2"])
        #expect(downloads.manifest(for: "GONE") == nil)
    }

    @Test func downloadFromMenuUpdatesStatusAndMenu() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
        let gate = AsyncGate()
        downloader.handler.withLock { $0 = { _, destination in await gate.wait(); try Data().write(to: destination) } }
        let (app, queue) = try await makeApp()
        let book = app.library.books[0]
        #expect(app.menuItems(for: book).map(\.action) == [.download])

        await app.perform(.download, on: book)
        try await waitUntil { await app.status(for: book) == .running(.download, progress: 0.5 * 0.96 + 0.02) }
        #expect(app.export.statusText == "Downloading 1 of 1…")
        #expect(app.export.activityTitle == "Downloading")
        guard case .cancel(_, .download) = app.menuItems(for: book).first?.action else {
            Issue.record("expected Cancel Download"); return
        }

        await gate.open()
        await queue.waitUntilFinished()
        // Finishing a job triggers a rescan.
        try await waitUntil { await app.status(for: book) == .downloaded }
        #expect(app.export.statusText == "1 downloaded")
        #expect(app.menuItems(for: book).map(\.action) == [.export, .showDownload, .deleteDownload])
    }

    @Test func statusTextCountsByKind() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
        let gate = AsyncGate()
        downloader.handler.withLock { $0 = { _, destination in await gate.wait(); try Data().write(to: destination) } }
        let (app, queue) = try await makeApp()
        app.export.destinationFolder = destination.url
        await app.export.download([app.library.books[0]])
        await app.export.exportOne(app.library.books[1])
        #expect(app.export.activityTitle == "Working")
        #expect(app.export.statusText == "Working on 1 of 2…")
        await gate.open()
        await queue.waitUntilFinished()
        try await waitUntil { await !app.export.isRunning }
        #expect(app.export.statusText == "1 downloaded, 1 exported")
        try await waitUntil { await app.status(for: app.library.books[1]) == .exported }
    }

    @Test func failureStaysUntilTheNextAttempt() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
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
        #expect(app.menuItems(for: book).map(\.action) == [.download])

        api.licenseHandler.withLock { $0 = { asin, _ in Fixtures.license(asin: asin) } }
        await app.export.download([book])
        await queue.waitUntilFinished()
        try await waitUntil { await app.status(for: book) == .downloaded }
    }

    @Test func deleteDownloadKeepsTheExport() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
        try keepDownload(Fixtures.book("B1", title: "Book B1"))
        try Data("m4b".utf8).write(to: destination.url.appendingPathComponent("Book B1 [B1].m4b"))
        let (app, _) = try await makeApp()
        app.export.destinationFolder = destination.url
        await app.rescan()
        #expect(app.status(for: app.library.books[0]) == .exported)

        await app.deleteDownload(app.library.books[0])
        #expect(app.downloadedFiles["B1"] == nil)
        #expect(app.exportedFiles["B1"] != nil)
        #expect(downloads.manifest(for: "B1") == nil)
        #expect(app.menuItems(for: app.library.books[0]).map(\.action) == [.download, .showExport])
    }

    @Test func signOutCancelsJobsAndKeepsFinishedFiles() async throws {
        defer { destination.cleanUp(); work.cleanUp() }
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
