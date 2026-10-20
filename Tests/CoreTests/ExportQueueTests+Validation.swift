import Foundation
import Testing
import LoudibleCore
import TestSupport

// MARK: Enqueue validation

extension ExportQueueTests {
    @Test func rejectsInvalidEnqueues() async throws {
        defer { cleanUp() }
        let (queue, _) = try await makeQueue()
        await #expect(throws: ExportQueue.StartError.nothingToExport) { try await queue.start(
            [],
            destination: destination.url) }
        let missing = destination.url.appendingPathComponent("missing")
        await #expect(throws: ExportQueue.StartError.destinationUnavailable(missing.path)) {
            try await queue.start(books(1), destination: missing)
        }
        try await queue.start(books(1), destination: destination.url)
        await queue.waitUntilFinished()
        try await queue.start(books(1), destination: destination.url) // a finished queue can start again
        await queue.waitUntilFinished()
    }

    @Test func createsMissingDownloadFolder() async throws {
        defer { cleanUp() }
        #expect(!FileManager.default.fileExists(atPath: downloads.folder.path))
        _ = try await runToCompletion(books(1), kind: .download)
        #expect(downloadsContents() == ["Book 1 [B000000001].aaxc"])
    }

    @Test func uncreatableDownloadFolderIsReported() async throws {
        defer { cleanUp() }
        // A regular file where the folder should be.
        let blocker = work.url.appendingPathComponent("NotAFolder")
        try Data().write(to: blocker)
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        let queue = ExportQueue(
            auth: auth, api: api, downloader: downloader, converter: converter,
            downloads: LocalDownloads(folder: blocker, manifestFolder: work.url.appendingPathComponent("M"))
        )
        await #expect(throws: ExportQueue.StartError.destinationUnavailable(blocker.path)) {
            try await queue.enqueue(books(1), kind: .download, exportDestination: nil)
        }
        #expect(await queue.currentSnapshot.jobs.isEmpty)
    }
}
