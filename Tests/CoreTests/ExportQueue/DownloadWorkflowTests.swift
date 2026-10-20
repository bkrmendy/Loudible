import Foundation
import Testing
@testable import LoudibleCore
import TestSupport

@Suite struct DownloadWorkflowTests {
    let fixture: ExportQueueTestFixture
    init() throws { fixture = try ExportQueueTestFixture() }

    @Test func directDownloadPersistsManifestAndReusesFile() async throws {
        defer { fixture.cleanUp() }
        let workflow = try await fixture.workflow()
        let book = fixture.books(1)[0]
        let result = try await workflow.run(book: book, kind: .download, context: fixture.context())
        #expect(result.freshLicense != nil)
        #expect(fixture.downloads.manifest(for: book.asin)?.book == book)
        let again = try await workflow.run(book: book, kind: .download, context: fixture.context())
        #expect(again.input == result.input)
        #expect(again.freshLicense == nil)
        #expect(fixture.api.requestedLicenses.current == [book.asin])
        #expect(fixture.downloads.partialDownloads().isEmpty)
    }

    @Test(arguments: [false, true]) func cancellationAppliesRecoveryPolicy(_ keep: Bool) async throws {
        defer { fixture.cleanUp() }
        let workflow = try await fixture.workflow()
        let started = AsyncGate()
        let cleanup = AsyncGate()
        fixture.downloader.handler.withLock {
            $0 = { _, _ in
                await started.open()
                await cleanup.wait()
                try Task.checkCancellation()
            }
        }
        let task = Task {
            try await workflow
                .run(book: fixture.books(1)[0], kind: .download, context: fixture.context(keepRecovery: keep))
        }
        await started.wait()
        task.cancel()
        await cleanup.open()
        _ = await task.result
        #expect((fixture.downloads.partialDownload(for: "B000000001") != nil) == keep)
        #expect(fixture.downloadsContents().isEmpty)
    }

    @Test func failureKeepsRecoveryAndNextRunResumes() async throws {
        defer { fixture.cleanUp() }
        let workflow = try await fixture.workflow()
        fixture.downloader.handler.withLock { $0 = { _, _ in throw ExporterError.download("failed") } }
        await #expect(throws: ExporterError.download("failed")) {
            try await workflow.run(book: fixture.books(1)[0], kind: .download, context: fixture.context())
        }
        fixture.downloader.handler.withLock { $0 = { _, url in try Data("audio".utf8).write(to: url) } }
        _ = try await workflow.run(book: fixture.books(1)[0], kind: .download, context: fixture.context())
        #expect(fixture.downloader.resumes.current.last! == MockDownloader.token)
    }
}
