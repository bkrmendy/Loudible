import Foundation
import Testing
@testable import LoudibleCore
import TestSupport

struct ExportQueueTestFixture {
    let api = MockAudibleAPI()
    let store = InMemoryCredentialStore(Fixtures.session())
    let downloader = MockDownloader()
    let converter = MockConverter()
    let destination: TemporaryDirectory
    let work: TemporaryDirectory
    let downloads: LocalDownloads

    init() throws {
        destination = try TemporaryDirectory("export-destination")
        work = try TemporaryDirectory("export-work")
        downloads = LocalDownloads(
            folder: work.url.appendingPathComponent("Downloads", isDirectory: true),
            manifestFolder: work.url.appendingPathComponent("Manifests", isDirectory: true),
            trash: { try FileManager.default.removeItem(at: $0) }
        )
        api.licenseHandler.withLock { $0 = { asin, _ in Fixtures.license(asin: asin) } }
    }

    /// One book at a time unless a test is about concurrency, so the order is deterministic.
    func makeQueue(maximumConcurrentBooks: Int = 1) async throws -> (ExportQueue, AuthenticationCoordinator) {
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        try await auth.restore()
        let queue = ExportQueue(
            auth: auth, api: api, downloader: downloader, converter: converter,
            downloads: downloads, maximumConcurrentBooks: maximumConcurrentBooks
        )
        return (queue, auth)
    }

    func books(_ count: Int) -> [Audiobook] {
        (1...count).map { Fixtures.book("B00000000\($0)", title: "Book \($0)") }
    }

    func runToCompletion(_ books: [Audiobook], kind: ExportJob.Kind = .export) async throws -> ExportQueue.Snapshot {
        let (queue, _) = try await makeQueue()
        try await queue.enqueue(books, kind: kind, exportDestination: destination.url)
        await queue.waitUntilFinished()
        return await queue.currentSnapshot
    }

    /// Everything in the downloads folder, hidden files included.
    func downloadsContents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: downloads.folder.path)) ?? []).sorted()
    }

    func manifestContents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: downloads.manifestFolder.path)) ?? []).sorted()
    }

    /// A kept download as an earlier run would have left it.
    func keepDownload(_ book: Audiobook, name: String? = nil, withManifest: Bool = true) throws -> URL {
        try downloads.ensureFolder()
        let url = downloads.folder.appendingPathComponent(name ?? "\(book.title) [\(book.asin)].aaxc")
        try Data("kept".utf8).write(to: url)
        if withManifest {
            let manifest = DownloadManifest(
                book: book, decryption: .aax(activationBytes: Data([1, 2, 3, 4])),
                chapters: [Chapter(title: "Stored", startMilliseconds: 0, lengthMilliseconds: 1)],
                downloadedAt: Fixtures.referenceDate)
            try downloads.writeManifest(manifest)
        }
        return url
    }

    func cleanUp() {
        destination.cleanUp()
        work.cleanUp()
    }
    func workflow() async throws -> DownloadWorkflow {
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        try await auth.restore()
        try downloads.ensureFolder()
        return DownloadWorkflow(licenses: LicenseProvider(auth: auth, api: api), downloader: downloader,
                                downloads: downloads, finalizer: ExportFileFinalizer())
    }

    func context(keepRecovery: Bool = false) -> ExportExecutionContext {
        ExportExecutionContext(report: { _ in }, keepsRecovery: { keepRecovery })
    }

}
