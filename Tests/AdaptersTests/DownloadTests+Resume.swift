import Foundation
@testable import LoudibleAdapters
import LoudibleCore
import TestSupport

extension DownloadTests {
    struct ResumeResult {
        let server: LocalHTTPServer
        let result: Data
        let checkpoints: [DownloadCheckpoint]
        let progress: [TransferProgress]
    }

    /// Downloads `file` into a destination that already holds `existing`, resuming from `resume`.
    func resume(
        _ file: LocalHTTPServer.File, existing: Data, from resume: ResumePoint,
        checkpointInterval: Int64 = 8 << 20
    ) async throws -> ResumeResult {
        let server = try LocalHTTPServer(reply: .file(file))
        defer { server.stop() }
        let url = try await server.start()
        let directory = try TemporaryDirectory("download")
        defer { directory.cleanUp() }
        let destination = directory.url.appendingPathComponent("book.aaxc")
        try existing.write(to: destination)
        let checkpoints = Locked<[DownloadCheckpoint]>([])
        let progress = Locked<[TransferProgress]>([])
        try await URLSessionFileDownloader(checkpointInterval: checkpointInterval).download(
            from: url, to: destination, resume: resume,
            checkpoint: { value in checkpoints.withLock { $0.append(value) } },
            progress: { value in progress.withLock { $0.append(value) } }
        )
        return ResumeResult(server: server, result: try Data(contentsOf: destination),
                            checkpoints: checkpoints.current, progress: progress.current)
    }
}
