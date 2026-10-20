import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct ExportQueueControlTests: ExportQueueTestCase {
    let fixture: ExportQueueTestFixture
    init() throws { fixture = try ExportQueueTestFixture() }

    @Test func cancelStopsCurrentAndQueuedBooksButKeepsCompleted() async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        let started = Locked(false)
        converter.handler.withLock {
            $0 = { request in
                if request.metadata.asin == "B000000002" {
                    try Data("partial".utf8).write(to: request.output)
                    started.withLock { $0 = true }
                    await gate.wait()
                    try Task.checkCancellation()
                }
                try Data("m4b".utf8).write(to: request.output)
            }
        }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(3), destination: destination.url)
        try await waitUntil { started.current }
        await queue.cancel()
        await gate.open()
        await queue.waitUntilFinished()

        let snapshot = await queue.currentSnapshot
        #expect(snapshot.jobs.map(\.state) == [
            .completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b")), .cancelled, .cancelled,
        ])
        #expect(destination.contents() == ["Book 1 [B000000001].m4b"])
        // Finished downloads are kept, including the one whose conversion was cancelled.
        #expect(downloadsContents() == ["Book 1 [B000000001].aaxc", "Book 2 [B000000002].aaxc"])
        #expect(api.requestedLicenses.current == ["B000000001", "B000000002"])
    }

    @Test(arguments: [ExportJob.Kind.download, .export])
    func cancelDuringDownloadRemovesThePartial(kind: ExportJob.Kind) async throws {
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
        try await queue.enqueue(books(1), kind: kind, exportDestination: destination.url)
        try await waitUntil { downloader.downloads.current.count == 1 }
        await queue.cancel()
        await gate.open()
        await queue.waitUntilFinished()
        #expect(await queue.currentSnapshot.jobs[0].state == .cancelled)
        #expect(downloadsContents().isEmpty)
        #expect(manifestContents().isEmpty)
        #expect(destination.contents().isEmpty)
    }

    @Test func cancellingRunningJobContinuesWithTheRest() async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        let started = Locked(false)
        converter.handler.withLock {
            $0 = { request in
                if request.metadata.asin == "B000000002" {
                    try Data("partial".utf8).write(to: request.output)
                    started.withLock { $0 = true }
                    await gate.wait()
                    try Task.checkCancellation()
                }
                try Data("m4b".utf8).write(to: request.output)
            }
        }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(3), destination: destination.url)
        try await waitUntil { started.current }
        await queue.cancel(await queue.currentSnapshot.jobs[1].id)
        await gate.open()
        await queue.waitUntilFinished()

        let snapshot = await queue.currentSnapshot
        #expect(snapshot.jobs.map(\.state) == [
            .completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b")),
            .cancelled,
            .completed(destination.url.appendingPathComponent("Book 3 [B000000003].m4b")),
        ])
        #expect(destination.contents() == ["Book 1 [B000000001].m4b", "Book 3 [B000000003].m4b"])
        #expect(!downloadsContents().contains(where: ExportFileNaming.isPartial))
        #expect(!snapshot.isRunning)
    }

    @Test func cancellingQueuedJobSkipsIt() async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        let started = Locked(false)
        converter.handler.withLock {
            $0 = { request in
                if request.metadata.asin == "B000000001" {
                    started.withLock { $0 = true }
                    await gate.wait()
                }
                try Data("m4b".utf8).write(to: request.output)
            }
        }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(3), destination: destination.url)
        try await waitUntil { started.current }
        await queue.cancel(await queue.currentSnapshot.jobs[1].id)
        #expect(await queue.currentSnapshot.jobs[1].state == .cancelled)
        await gate.open()
        await queue.waitUntilFinished()

        let snapshot = await queue.currentSnapshot
        #expect(snapshot.jobs.map(\.state) == [
            .completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b")),
            .cancelled,
            .completed(destination.url.appendingPathComponent("Book 3 [B000000003].m4b")),
        ])
        #expect(api.requestedLicenses.current == ["B000000001", "B000000003"])
    }

    @Test func cancellingFinishedOrUnknownJobChangesNothing() async throws {
        defer { cleanUp() }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(1), destination: destination.url)
        await queue.waitUntilFinished()
        let before = await queue.currentSnapshot
        await queue.cancel(before.jobs[0].id)
        await queue.cancel(UUID())
        #expect(await queue.currentSnapshot == before)
    }

    @Test func clearForgetsFinishedJobsButNotRunningOnes() async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        converter.handler
            .withLock { $0 = { request in await gate.wait(); try Data("m4b".utf8).write(to: request.output) } }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(1), destination: destination.url)
        await queue.clear()
        #expect(await queue.currentSnapshot.jobs.count == 1)
        await gate.open()
        await queue.waitUntilFinished()
        await queue.clear()
        #expect(await queue.currentSnapshot == ExportQueue.Snapshot())
        #expect(destination.contents() == ["Book 1 [B000000001].m4b"])
    }
}
