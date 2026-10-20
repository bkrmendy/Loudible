import Foundation
import LoudibleCore
import TestSupport

/// Shared conveniences for integration suites; test declarations stay in their own files.
protocol ExportQueueTestCase {
    var fixture: ExportQueueTestFixture { get }
}

extension ExportQueueTestCase {
    var api: MockAudibleAPI { fixture.api }
    var store: InMemoryCredentialStore { fixture.store }
    var downloader: MockDownloader { fixture.downloader }
    var converter: MockConverter { fixture.converter }
    var destination: TemporaryDirectory { fixture.destination }
    var work: TemporaryDirectory { fixture.work }
    var downloads: LocalDownloads { fixture.downloads }

    func makeQueue(maximumConcurrentBooks: Int = 1) async throws -> (ExportQueue, AuthenticationCoordinator) {
        try await fixture.makeQueue(maximumConcurrentBooks: maximumConcurrentBooks)
    }
    func books(_ count: Int) -> [Audiobook] { fixture.books(count) }
    func runToCompletion(_ books: [Audiobook], kind: ExportJob.Kind = .export) async throws -> ExportQueue.Snapshot {
        try await fixture.runToCompletion(books, kind: kind)
    }
    func downloadsContents() -> [String] { fixture.downloadsContents() }
    func manifestContents() -> [String] { fixture.manifestContents() }
    func keepDownload(_ book: Audiobook, name: String? = nil, withManifest: Bool = true) throws -> URL {
        try fixture.keepDownload(book, name: name, withManifest: withManifest)
    }
    func cleanUp() { fixture.cleanUp() }
}
