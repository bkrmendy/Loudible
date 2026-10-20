import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct ExportQueueSchedulingTests {
    let fixture: ExportQueueTestFixture
    init() throws { fixture = try ExportQueueTestFixture() }

    @Test(arguments: [false, true]) func cancellationRetainsSlotThroughCleanup(_ cancelAll: Bool) async throws {
        defer { fixture.cleanUp() }
        let started = AsyncGate()
        let cleanup = AsyncGate()
        let calls = Locked(0)
        fixture.downloader.handler.withLock {
            $0 = { _, destination in
                let first = calls.withLock { count in count += 1; return count == 1 }
                if first {
                    await started.open()
                    await cleanup.wait()
                    try Task.checkCancellation()
                }
                try Data("audio".utf8).write(to: destination)
            }
        }
        let books = fixture.books(3)
        let (queue, _) = try await fixture.makeQueue()
        let first = try await queue.enqueue([books[0]], kind: .download, exportDestination: nil)[0]
        await started.wait()
        try await queue.start(Array(books.prefix(2)), destination: fixture.destination.url)
        if cancelAll { await queue.cancel() } else { await queue.cancel(first) }
        try await queue.enqueue([books[2]], kind: .download, exportDestination: nil)
        let waiting = await queue.currentSnapshot
        #expect(waiting.isRunning)
        #expect(waiting.jobs.last?.state == .queued)
        #expect(fixture.api.requestedLicenses.current == [books[0].asin])
        #expect(calls.current == 1)
        await cleanup.open()
        await queue.waitUntilFinished()
        let final = await queue.currentSnapshot
        #expect(!final.isRunning)
        #expect(final.jobs[0].state == .cancelled)
        #expect(final.jobs.filter { $0.state == .cancelled }.count == (cancelAll ? 3 : 1))
        #expect(final.jobs.last?.state.isFinished == true)
        #expect(fixture.downloads.scanDownloads()[books[2].asin] != nil)
    }

    @Test func cancellingLastAuthenticationWaiterAdmitsOfflineExport() async throws {
        defer { fixture.cleanUp() }
        let books = fixture.books(2)
        _ = try fixture.keepDownload(books[1])
        fixture.api.licenseHandler.withLock { $0 = { _, _ in throw ExporterError.authenticationRequired } }
        fixture.api.refreshHandler.withLock { $0 = { _ in throw ExporterError.authenticationRequired } }
        let (queue, _) = try await fixture.makeQueue()
        try await queue.start(books, destination: fixture.destination.url)
        try await waitUntil { await queue.currentSnapshot.isWaitingForAuthentication }
        let id = await queue.currentSnapshot.jobs[0].id
        await queue.cancel(id)
        await queue.cancel(id)
        await queue.resumeAfterAuthentication()
        await queue.waitUntilFinished()
        let final = await queue.currentSnapshot
        #expect(final.jobs[0].state == .cancelled)
        #expect(final.jobs[1].state == .completed(
            fixture.destination.url.appendingPathComponent("Book 2 [B000000002].m4b")))
        #expect(!final.isWaitingForAuthentication)
    }
}
