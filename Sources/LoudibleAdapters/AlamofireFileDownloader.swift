import Alamofire
import Foundation
import LoudibleCore

/// Downloads through Alamofire, keeping native resume data opaque. An unusable token gets one
/// fresh attempt at the supplied URL; URLSession owns the temporary bytes between attempts.
public struct AlamofireFileDownloader: FileDownloader {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func download(
        from url: URL,
        to destination: URL,
        resumeData: Data?,
        recovery: @escaping @Sendable (DownloadRecovery) -> Void,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        let session = Session(configuration: configuration, startRequestsImmediately: false)
        // Clear consumed recovery before starting: a crash must not reuse an outdated token.
        recovery(DownloadRecovery())
        let first = await DownloadAttempt().run(
            session: session, url: url, destination: destination, resumeData: resumeData, progress: progress)
        if Task.isCancelled {
            recovery(first.recovery)
            throw ExporterError.cancelled
        }
        let result: DownloadAttempt.Outcome
        if resumeData != nil, let error = first.response.error, !error.isDestinationFailure,
           !error.isExplicitlyCancelledError {
            try? FileManager.default.removeItem(at: destination)
            recovery(DownloadRecovery())
            result = await DownloadAttempt().run(
                session: session, url: url, destination: destination, resumeData: nil, progress: progress)
        } else {
            result = first
        }
        recovery(result.recovery)
        if Task.isCancelled { throw ExporterError.cancelled }
        if let error = result.response.error {
            try? FileManager.default.removeItem(at: destination)
            if error.isDestinationFailure {
                throw ExporterError.fileSystem("Could not save download: \(error.localizedDescription)")
            }
            if let status = result.response.response?.statusCode, ![200, 201, 203, 206].contains(status) {
                throw ExporterError.download("HTTP \(status)")
            }
            throw ExporterError.download(error.localizedDescription)
        }
    }
}

/// Callback state belongs to `queue`; only cancellation and request installation share a lock.
private final class DownloadAttempt: @unchecked Sendable {
    struct Outcome: Sendable {
        let response: AFDownloadResponse<URL?>
        let recovery: DownloadRecovery
    }

    private let queue = DispatchQueue(label: "Loudible.DownloadAttempt")
    private let lock = NSLock()
    private var request: DownloadRequest?
    private var cancelled = false
    private var lastProgress: TransferProgress?

    func run(
        session: Session, url: URL, destination: URL, resumeData: Data?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let target: DownloadRequest.Destination = { _, _ in (destination, [.removePreviousFile]) }
                let request = if let resumeData {
                    session.download(resumingWith: resumeData, to: target)
                } else {
                    session.download(url, to: target)
                }
                request.validate(statusCode: resumeData == nil ? [200, 201, 203] : [200, 201, 203, 206])
                    .downloadProgress(queue: queue) { [self] value in
                        let value = TransferProgress(
                            bytesReceived: value.completedUnitCount, bytesExpected: max(0, value.totalUnitCount))
                        lastProgress = value
                        if value.bytesExpected > 0 { progress(value) }
                    }
                    .response(queue: queue) { [self] response in
                        if response.error == nil, let file = response.fileURL,
                           let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 {
                            let completed = TransferProgress(bytesReceived: size, bytesExpected: size)
                            lastProgress = completed
                            progress(completed)
                        }
                        let recovery = DownloadRecovery(
                            resumeData: response.error == nil ? nil : response.resumeData, progress: lastProgress)
                        continuation.resume(returning: Outcome(response: response, recovery: recovery))
                    }
                start(request)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func start(_ request: DownloadRequest) {
        lock.lock()
        self.request = request
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { request.cancel(producingResumeData: true) } else { request.resume() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let request = self.request
        lock.unlock()
        request?.cancel(producingResumeData: true)
    }
}

private extension AFError {
    var isDestinationFailure: Bool {
        if isDownloadedFileMoveError { return true }
        guard let error = underlyingError as NSError? else { return false }
        if error.domain == NSCocoaErrorDomain { return true }
        return error.domain == NSURLErrorDomain && [
            NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile, NSURLErrorCannotCloseFile,
            NSURLErrorCannotWriteToFile, NSURLErrorCannotRemoveFile, NSURLErrorCannotMoveFile
        ].contains(error.code)
    }
}
