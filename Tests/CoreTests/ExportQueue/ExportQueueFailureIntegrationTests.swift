import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct ExportQueueFailureIntegrationTests: ExportQueueTestCase {
    let fixture: ExportQueueTestFixture
    init() throws { fixture = try ExportQueueTestFixture() }

    @Test func failureContinuesWithNextBookAndKeepsCompletedExports() async throws {
        defer { cleanUp() }
        api.licenseHandler.withLock {
            $0 = { asin, _ in
                if asin == "B000000002" { throw ExporterError.unsupportedDRM(asin: asin, drmType: "Widevine") }
                return Fixtures.license(asin: asin)
            }
        }
        let snapshot = try await runToCompletion(books(3))
        #expect(snapshot.jobs[0].state == .completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b")))
        #expect(snapshot.jobs[1].state == .failed("Book 2: This title uses unsupported DRM (Widevine)."))
        #expect(snapshot.jobs[2].state == .completed(destination.url.appendingPathComponent("Book 3 [B000000003].m4b")))
        #expect(destination.contents() == ["Book 1 [B000000001].m4b", "Book 3 [B000000003].m4b"])
    }

    @Test(arguments: [ExportJob.Kind.download, .export])
    func downloadFailureKeepsRecoveryForTheNextDownload(kind: ExportJob.Kind) async throws {
        defer { cleanUp() }
        downloader.handler.withLock {
            $0 = { _, destination in
                try Data("partial".utf8).write(to: destination)
                throw ExporterError.download("HTTP 500")
            }
        }
        let snapshot = try await runToCompletion(books(1), kind: kind)
        #expect(snapshot.jobs[0].state == .failed("Book 1: Download failed: HTTP 500"))
        #expect(downloadsContents().isEmpty)
        #expect(manifestContents() == ["B000000001.partial"])
        let record = try #require(downloads.partialDownload(for: "B000000001"))
        #expect(record.customerID == Fixtures.session().customerID)
        #expect(record.recovery == DownloadRecovery(
            resumeData: MockDownloader.token, progress: TransferProgress(bytesReceived: 50, bytesExpected: 100)))
        #expect(destination.contents().isEmpty)
        #expect(converter.requests.current.isEmpty)
    }

    @Test func nextDownloadReusesRecoveryWithAFreshLicense() async throws {
        defer { cleanUp() }
        downloader.handler.withLock {
            $0 = { _, destination in
                try Data("partial".utf8).write(to: destination)
                throw ExporterError.download("HTTP 500")
            }
        }
        let (queue, _) = try await makeQueue()
        try await queue.enqueue(books(1), kind: .download, exportDestination: nil)
        await queue.waitUntilFinished()
        downloader.handler.withLock { $0 = { _, destination in try Data("encrypted".utf8).write(to: destination) } }

        try await queue.enqueue(books(1), kind: .download, exportDestination: nil)
        await queue.waitUntilFinished()

        #expect(await queue.currentSnapshot.jobs[0]
            .state == .completed(downloads.folder.appendingPathComponent("Book 1 [B000000001].aaxc")))
        #expect(downloader.resumes.current.first! == nil)
        #expect(downloader.resumes.current.last! == MockDownloader.token)
        #expect(api.requestedLicenses.current == ["B000000001", "B000000001"])
        #expect(downloadsContents() == ["Book 1 [B000000001].aaxc"])
        #expect(manifestContents() == ["B000000001.json"])
    }

    @Test func anotherAccountsRecoveryIsDiscarded() async throws {
        defer { cleanUp() }
        try downloads.ensureFolder()
        try Data("theirs".utf8).write(to: downloads.partialFileURL(for: "B000000001"))
        try downloads.writePartialDownload(PartialDownload(
            book: books(1)[0], customerID: "amzn1.account.SOMEONE.ELSE", fileExtension: "aaxc",
            recovery: DownloadRecovery(resumeData: MockDownloader.token),
            decryption: Fixtures.license(asin: "B000000001").decryption,
            updatedAt: Fixtures.referenceDate))
        let snapshot = try await runToCompletion(books(1), kind: .download)
        #expect(snapshot.jobs[0]
            .state == .completed(downloads.folder.appendingPathComponent("Book 1 [B000000001].aaxc")))
        #expect(downloader.resumes.current.first! == nil)
        #expect(try Data(contentsOf: downloads.folder.appendingPathComponent("Book 1 [B000000001].aaxc")) ==
            Data("encrypted".utf8))
        #expect(manifestContents() == ["B000000001.json"])
    }

    @Test func incompatibleLicenseDiscardsTheNativeToken() async throws {
        defer { cleanUp() }
        try downloads.ensureFolder()
        try downloads.writePartialDownload(PartialDownload(
            book: books(1)[0], customerID: Fixtures.session().customerID, fileExtension: "aaxc",
            recovery: DownloadRecovery(resumeData: MockDownloader.token),
            decryption: .aaxc(key: Data(repeating: 99, count: 16), iv: Data(repeating: 98, count: 16)),
            updatedAt: Fixtures.referenceDate))
        _ = try await runToCompletion(books(1), kind: .download)
        #expect(downloader.resumes.current == [nil])
        #expect(downloads.partialDownloads().isEmpty)
    }

    @Test(arguments: [ExportJob.Kind.download, .export])
    func suspendDuringDownloadKeepsRecovery(kind: ExportJob.Kind) async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        downloader.handler.withLock {
            $0 = { _, destination in
                try Data("partial".utf8).write(to: destination)
                await gate.wait()
                throw ExporterError.cancelled
            }
        }
        let (queue, _) = try await makeQueue()
        try await queue.enqueue(
            books(1) + [Fixtures.book("B000000002", title: "Book 2")],
            kind: kind,
            exportDestination: destination.url)
        try await waitUntil { downloader.downloads.current.count == 1 }
        await queue.suspend()
        await gate.open()
        await queue.waitUntilFinished()
        #expect(await queue.currentSnapshot.jobs.map(\.state) == [.cancelled, .cancelled])
        #expect(downloadsContents().isEmpty)
        #expect(manifestContents() == ["B000000001.partial"])
        #expect(downloads.partialDownload(for: "B000000001")?.recovery.resumeData == MockDownloader.token)
        #expect(destination.contents().isEmpty)
    }

    @Test func conversionFailureRemovesPartialOutputButKeepsDownload() async throws {
        defer { cleanUp() }
        converter.handler.withLock {
            $0 = { request in
                try Data("half".utf8).write(to: request.output)
                throw ExporterError.conversion("bad packet")
            }
        }
        let snapshot = try await runToCompletion(books(1))
        #expect(snapshot.jobs[0].state == .failed("Book 1: Conversion failed: bad packet"))
        #expect(destination.contents().isEmpty)
        #expect(downloadsContents() == ["Book 1 [B000000001].aaxc"])
    }

    @Test func converterWithoutOutputFails() async throws {
        defer { cleanUp() }
        converter.handler.withLock { $0 = { _ in } }
        let snapshot = try await runToCompletion(books(1))
        #expect(snapshot.jobs[0]
            .state == .failed("Book 1: Conversion failed: The converter did not produce an output file."))
    }

    @Test func deniedLicenseIsTitleSpecific() async throws {
        defer { cleanUp() }
        api.licenseHandler.withLock { $0 = { asin, _ in throw ExporterError.licenseDenied(
            asin: asin,
            reason: "not owned") } }
        let snapshot = try await runToCompletion(books(1))
        #expect(snapshot.jobs[0].state == .failed("Book 1: The download license was denied: not owned"))
        #expect(downloader.downloads.current.isEmpty)
    }
}
