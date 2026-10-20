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
            trash: { try FileManager.default.removeItem(at: $0) })
        api.licenseHandler.withLock { $0 = { asin, _ in Fixtures.license(asin: asin) } }
        api.libraryHandler.withLock {
            $0 = { _, _, marketplace, _ in LibraryPage(entries: marketplace == .us ? [
                Fixtures.entry("B1"),
                Fixtures.entry("B2")
            ] : []) }
        }
    }

    func makeApp() async throws -> (AppViewModel, ExportQueue) {
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        let queue = ExportQueue(
            auth: auth,
            api: api,
            downloader: downloader,
            converter: converter,
            downloads: downloads,
            maximumConcurrentBooks: 1)
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
        converter.handler
            .withLock { $0 = { request in
            await gate.wait(); try Task.checkCancellation(); try Data().write(to: request.output) } }
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
        api.registerHandler
            .withLock { $0 = { _, _ in renewed.withLock { $0 = true }; return Fixtures.session(accessToken: "fresh") } }
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
}
