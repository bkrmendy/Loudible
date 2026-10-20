import Foundation
@testable import LoudibleAdapters
import LoudibleCore
import Testing
import TestSupport

@Suite(.serialized) struct DownloadRecoveryTests {
    let payload = Data((0..<500_000).map { UInt8($0 % 251) })

    /// Produces a real native token rather than fabricating URLSession's private representation.
    private func interrupt(_ url: URL, destination: URL) async throws -> DownloadRecovery {
        let received = Locked(false)
        let saved = Locked(DownloadRecovery())
        let task = Task {
            try await AlamofireFileDownloader().download(
                from: url, to: destination, resumeData: nil,
                recovery: { value in saved.withLock { $0 = value } },
                progress: { value in
                    if value.transferred.bytesReceived > 0 { received.withLock { $0 = true } }
                })
        }
        defer { task.cancel() }
        try await waitUntil { received.current }
        task.cancel()
        _ = await task.result
        _ = try #require(saved.current.resumeData)
        return saved.current
    }

    @Test func persistedTokenResumesWithANewDownloader() async throws {
        let server = try LocalHTTPServer(body: payload)
        defer { server.stop() }
        let url = try await server.start()
        let directory = try TemporaryDirectory("native-resume")
        defer { directory.cleanUp() }
        let destination = directory.url.appendingPathComponent("book.aaxc")
        let record = directory.url.appendingPathComponent("recovery.json")
        let recovery = try await interrupt(url, destination: destination)
        try JSONEncoder().encode(recovery).write(to: record)
        let reloaded = try JSONDecoder().decode(DownloadRecovery.self, from: Data(contentsOf: record))
        server.finishTransfers()

        try await AlamofireFileDownloader().download(
            from: url, to: destination, resumeData: reloaded.resumeData, recovery: { _ in }, progress: { _ in })

        #expect(try Data(contentsOf: destination) == payload)
        #expect(server.requestCount == 2)
        #expect(server.requests.last?["range"] != nil)
    }

    @Test func expiredOriginalURLFallsBackOnceToFreshURL() async throws {
        let original = try LocalHTTPServer(body: payload)
        let fresh = try LocalHTTPServer(body: payload)
        defer {
            original.stop()
            fresh.stop()
        }
        let originalURL = try await original.start()
        let freshURL = try await fresh.start()
        let directory = try TemporaryDirectory("native-fallback")
        defer { directory.cleanUp() }
        let destination = directory.url.appendingPathComponent("book.aaxc")
        let saved = try await interrupt(originalURL, destination: destination)
        original.finishTransfers(expired: true)
        fresh.finishTransfers()
        let finalRecovery = Locked(DownloadRecovery())
        let events = Locked<[DownloadProgress]>([])

        try await AlamofireFileDownloader().download(
            from: freshURL, to: destination, resumeData: saved.resumeData,
            recovery: { value in finalRecovery.withLock { $0 = value } },
            progress: { value in events.withLock { $0.append(value) } })

        #expect(try Data(contentsOf: destination) == payload)
        #expect(original.requestCount == 2)
        #expect(fresh.requestCount == 1)
        #expect(finalRecovery.current.resumeData == nil)
        #expect(events.current.first?.attempt == 0)
        let fallback = events.current.filter { $0.attempt == 1 }
        #expect(fallback.first?.transferred == TransferProgress(bytesReceived: 0, bytesExpected: 0))
        #expect(fallback.last?.transferred == TransferProgress(bytesReceived: Int64(payload.count),
                                                             bytesExpected: Int64(payload.count)))
    }
}
