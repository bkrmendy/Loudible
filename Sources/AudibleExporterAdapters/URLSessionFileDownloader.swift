import Foundation
import AudibleExporterCore

/// Downloads a file completely with URLSession. Verifies the HTTP status and, when the
/// server announced it, the byte count. Leaves nothing at `destination` unless it succeeded.
public struct URLSessionFileDownloader: FileDownloader {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    delegate.start(session.downloadTask(with: url), continuation: continuation)
                }
            } onCancel: {
                delegate.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if Task.isCancelled { throw ExporterError.cancelled }
            throw error
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finishError: (any Error)?
    private var isCancelled = false

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        self.task = task
        self.continuation = continuation
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { task.cancel() } else { task.resume() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns, so validate and move it now.
        let error: (any Error)?
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            error = ExporterError.download("HTTP \(response.statusCode)")
        } else if downloadTask.countOfBytesExpectedToReceive > 0,
                  downloadTask.countOfBytesReceived != downloadTask.countOfBytesExpectedToReceive {
            error = ExporterError.download(
                "Received \(downloadTask.countOfBytesReceived) of \(downloadTask.countOfBytesExpectedToReceive) bytes"
            )
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                error = nil
            } catch let moveError {
                error = ExporterError.fileSystem("Could not save download: \(moveError.localizedDescription)")
            }
        }
        lock.lock()
        finishError = error
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let finishError = self.finishError
        let cancelled = isCancelled
        lock.unlock()

        if cancelled {
            continuation?.resume(throwing: ExporterError.cancelled)
        } else if let error {
            continuation?.resume(throwing: ExporterError.download(error.localizedDescription))
        } else if let finishError {
            continuation?.resume(throwing: finishError)
        } else {
            progress(1)
            continuation?.resume()
        }
    }
}
