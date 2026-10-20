import Foundation
import Testing
import LoudibleCore
import LoudiblePresentation
import TestSupport

// MARK: Downloads

extension ExportViewModelTests {
    /// A download as an earlier run left it: the audio file and its manifest.
    func keepDownload(_ book: Audiobook) throws {
        try downloads.ensureFolder()
        try Data("enc".utf8).write(to: downloads.folder.appendingPathComponent("\(book.title) [\(book.asin)].aaxc"))
        try downloads.writeManifest(DownloadManifest(
            book: book,
            decryption: Fixtures.license(asin: book.asin).decryption,
            chapters: [],
            downloadedAt: Fixtures.referenceDate))
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
        api.licenseHandler.withLock { $0 = { asin, _ in throw ExporterError.licenseDenied(
            asin: asin,
            reason: "not owned") } }
        let (app, queue) = try await makeApp()
        let book = app.library.books[0]
        await app.export.download([book])
        await queue.waitUntilFinished()
        try await waitUntil { await app.status(for: book) == .failed(
            .download,
            "The download license was denied: not owned") }

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

    @Test func signOutPausesDownloadsAndSigningInAgainContinuesThem() async throws {
        defer { work.cleanUp() }
        downloader.handler.withLock {
            $0 = { source, destination in
                // B2 only ends by being stopped, reporting native recovery through the mock.
                if source.lastPathComponent.hasPrefix("B2") {
                    try Data("enc".utf8).write(to: destination)
                    try await Task.sleep(for: .seconds(60))
                }
                try Data("encrypted".utf8).write(to: destination)
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
        #expect(app.partialDownloads == ["B2": TransferProgress(
            bytesReceived: 50,
            bytesExpected: 100)])
        try await waitUntil { await app.library.books.isEmpty }

        downloader.handler.withLock { $0 = { _, destination in try Data("encrypted".utf8).write(to: destination) } }
        api.registerHandler.withLock { $0 = { _, _ in Fixtures.session() } }
        await app.session.signIn()
        await app.session.completeSignIn(with: Fixtures.callbackURL())
        try await waitUntil { downloads.scanDownloads().keys.sorted() == ["B1", "B2"] }
        #expect(downloader.resumes.current.last! == MockDownloader.token)
        try await waitUntil { await app.partialDownloads.isEmpty }
    }

    /// Native recovery from an earlier run.
    func keepPartial(_ asin: String, customerID: String = Fixtures.session().customerID,
                     token: Data? = MockDownloader.token) throws {
        try downloads.ensureFolder()
        try downloads.writePartialDownload(PartialDownload(
            book: Fixtures.book(asin), customerID: customerID, fileExtension: "aaxc",
            recovery: DownloadRecovery(resumeData: token,
                progress: TransferProgress(bytesReceived: 3, bytesExpected: 9)),
            decryption: Fixtures.license(asin: asin).decryption,
            updatedAt: Fixtures.referenceDate
        ))
    }

    @Test(arguments: [true, false])
    func launchContinuesTheAccountsDownloadsAndDropsTheRest(hasToken: Bool) async throws {
        defer { work.cleanUp() }
        let token = hasToken ? MockDownloader.token : nil
        try keepPartial("B1", token: token)
        try keepPartial("B2", customerID: "amzn1.account.SOMEONE.ELSE")
        try keepPartial("B9")  // no longer in the library
        let (app, queue) = try await makeApp()
        await queue.waitUntilFinished()
        try await waitUntil { await app.downloadedFiles.keys.sorted() == ["B1"] }
        #expect(downloader.resumes.current == [token])
        #expect(downloads.partialDownloads().isEmpty)
        #expect(app.partialDownloads.isEmpty)
        #expect(app.status(for: app.library.books[1]) == .none)
    }

    @Test func signedOutLaunchKeepsRecoveryAndShowsItPaused() async throws {
        defer { work.cleanUp() }
        store.stored.withLock { $0 = nil }
        try keepPartial("B1")
        let (app, _) = try await makeApp()
        #expect(!app.session.isSignedIn)
        #expect(downloader.downloads.current.isEmpty)
        let kept = TransferProgress(bytesReceived: 3, bytesExpected: 9)
        #expect(app.partialDownloads == ["B1": kept])
        #expect(app.status(for: Fixtures.book("B1")) == .paused(kept))
    }

    @Test func failedLibraryLoadDeletesNothing() async throws {
        defer { work.cleanUp() }
        api.libraryHandler.withLock { $0 = { _, _, _, _ in throw ExporterError.network("offline") } }
        try keepPartial("B9")
        let (app, _) = try await makeApp()
        #expect(app.library.errorMessage != nil)
        #expect(downloads.partialDownload(for: "B9") != nil)
        #expect(downloader.downloads.current.isEmpty)
    }

    @Test func failedDownloadKeepsRecoveryUntilResumedOrDiscarded() async throws {
        defer { work.cleanUp() }
        downloader.handler.withLock {
            $0 = { _, destination in
                try Data("enc".utf8).write(to: destination)
                throw ExporterError.download("HTTP 500")
            }
        }
        let (app, queue) = try await makeApp()
        let book = app.library.books[0]
        await app.export.download([book])
        await queue.waitUntilFinished()
        let kept = TransferProgress(bytesReceived: 50, bytesExpected: 100)
        try await waitUntil {
            await app.status(for: book) == .failed(.download, "Download failed: HTTP 500", kept: kept) }
        #expect(app.menuItems(for: book).map(\.action) == [.resumeDownload, .export, .deleteDownload])
        #expect(app.selectedBooks(offering: .download).isEmpty)
        app.library.toggleSelection(book.asin)
        #expect(app.selectedBooks(offering: .download) == [book])

        // A refresh doesn't retry it by itself.
        await app.refreshLibrary()
        #expect(downloader.downloads.current.count == 1)

        await app.deleteDownload(book)
        #expect(app.status(for: book) == .failed(.download, "Download failed: HTTP 500"))
        #expect(downloads.partialDownloads().isEmpty)
        #expect(app.menuItems(for: book).map(\.action) == [.download, .export])
    }

    @Test func resumeDownloadReusesTheNativeToken() async throws {
        defer { work.cleanUp() }
        downloader.handler.withLock {
            $0 = { _, destination in
                try Data("enc".utf8).write(to: destination)
                throw ExporterError.download("HTTP 500")
            }
        }
        let (app, queue) = try await makeApp()
        let book = app.library.books[0]
        await app.perform(.download, on: book)
        await queue.waitUntilFinished()
        try await waitUntil { await app.partialDownloads[book.asin] != nil }

        downloader.handler.withLock { $0 = { _, destination in try Data("encrypted".utf8).write(to: destination) } }
        await app.perform(.resumeDownload, on: book)
        await queue.waitUntilFinished()
        try await waitUntil { await app.status(for: book) == .downloaded }
        #expect(downloader.resumes.current.last! == MockDownloader.token)
        #expect(app.partialDownloads.isEmpty)
    }
}
