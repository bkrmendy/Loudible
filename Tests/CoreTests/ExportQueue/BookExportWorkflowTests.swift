import Foundation
import Testing
@testable import LoudibleCore
import TestSupport

@Suite struct BookExportWorkflowTests {
    let fixture: ExportQueueTestFixture
    init() throws { fixture = try ExportQueueTestFixture() }

    private func workflow() async throws -> BookExportWorkflow {
        BookExportWorkflow(download: try await fixture.workflow(), converter: fixture.converter,
                           finalizer: ExportFileFinalizer())
    }

    @Test(arguments: [false, true]) func keptFileUsesManifestOrFreshLicense(_ withManifest: Bool) async throws {
        defer { fixture.cleanUp() }
        let book = fixture.books(1)[0]
        let kept = try fixture.keepDownload(book, withManifest: withManifest)
        let workflow = try await workflow()
        let output = try await workflow
            .run(book: book, destination: fixture.destination.url, context: fixture.context())
        let request = try #require(fixture.converter.requests.current.first)
        #expect(request.input == kept)
        #expect(request.metadata.asin == book.asin)
        #expect(request.decryption == (withManifest ? fixture.downloads.manifest(for: book.asin)?.decryption
            : Fixtures.license(asin: book.asin).decryption))
        #expect(fixture.api.requestedLicenses.current.count == (withManifest ? 0 : 1))
        #expect(fixture.downloader.downloads.current.isEmpty)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func freshDownloadSharesLicenseWithConversion() async throws {
        defer { fixture.cleanUp() }
        let workflow = try await workflow()
        let book = fixture.books(1)[0]
        _ = try await workflow.run(book: book, destination: fixture.destination.url, context: fixture.context())
        #expect(fixture.api.requestedLicenses.current == [book.asin])
        #expect(fixture.converter.requests.current.first?.decryption == Fixtures.license(asin: book.asin).decryption)
        #expect(fixture.downloadsContents() == ["Book 1 [B000000001].aaxc"])
    }

    @Test func failedConversionCleansOutputAndSuggestsRedownload() async throws {
        defer { fixture.cleanUp() }
        let book = fixture.books(1)[0]
        _ = try fixture.keepDownload(book)
        let workflow = try await workflow()
        fixture.converter.handler.withLock {
            $0 = { request in
                try Data("partial".utf8).write(to: request.output)
                throw ExporterError.conversion("bad")
            }
        }
        await #expect(throws: ExporterError.conversion("bad " + BookExportWorkflow.redownloadHint)) {
            try await workflow.run(book: book, destination: fixture.destination.url, context: fixture.context())
        }
        #expect(fixture.destination.contents().isEmpty)
        #expect(fixture.downloads.scanDownloads()[book.asin] != nil)
    }

    @Test func cancellationDuringFinalizingRemovesOutputAndKeepsDownload() async throws {
        defer { fixture.cleanUp() }
        let workflow = try await workflow()
        let book = fixture.books(1)[0]
        let finalizing = AsyncGate()
        let release = AsyncGate()
        let context = ExportExecutionContext(report: { event in
            if case .phase(.finalizing) = event {
                await finalizing.open()
                await release.wait()
            }
        }, keepsRecovery: { false })
        let task = Task {
            try await workflow.run(book: book, destination: fixture.destination.url, context: context)
        }
        await finalizing.wait()
        task.cancel()
        await release.open()

        await #expect(throws: ExporterError.cancelled) { try await task.value }
        #expect(fixture.destination.contents().isEmpty)
        #expect(fixture.downloads.scanDownloads()[book.asin] != nil)
    }

    @Test func missingOutputFails() async throws {
        defer { fixture.cleanUp() }
        let workflow = try await workflow()
        fixture.converter.handler.withLock { $0 = { _ in } }
        await #expect(throws: ExporterError.conversion("The converter did not produce an output file.")) {
            try await workflow.run(book: fixture.books(1)[0], destination: fixture.destination.url,
                                   context: fixture.context())
        }
    }
}
