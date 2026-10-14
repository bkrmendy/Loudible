import Foundation
import LoudibleCore

/// Downloads a file with URLSession, streaming it to `destination` so an interrupted download
/// can be continued, even after a crash. Verifies the HTTP status and, when the server announced
/// it, the byte count.
///
/// Resuming asks for the rest with `Range` and `If-Range`, and appends only when the server's
/// `206` answer starts where the file ends and describes the same file (validator and total
/// length). Anything else starts over: a `200`, a different file, or a `416`. Written bytes are
/// flushed to disk every `checkpointInterval` bytes and when the transfer ends, each time followed
/// by a checkpoint.
public struct URLSessionFileDownloader: FileDownloader {
    private let configuration: URLSessionConfiguration
    private let checkpointInterval: Int64

    public init(configuration: URLSessionConfiguration = .ephemeral, checkpointInterval: Int64 = 8 << 20) {
        self.configuration = configuration
        self.checkpointInterval = max(1, checkpointInterval)
    }

    public func download(
        from url: URL,
        to destination: URL,
        resume: ResumePoint?,
        checkpoint: @escaping @Sendable (DownloadCheckpoint) -> Void,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        let delegate = DownloadDelegate(
            url: url, destination: destination, resume: resume,
            checkpointInterval: checkpointInterval, checkpoint: checkpoint, progress: progress
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    delegate.start(in: session, continuation: continuation)
                }
            } onCancel: {
                delegate.cancel()
            }
        } catch {
            if Task.isCancelled { throw ExporterError.cancelled }
            throw error
        }
    }
}

/// Everything but `cancel()` runs on the session's serial delegate queue; the lock guards what
/// `cancel()` shares with it.
private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let resume: ResumePoint?
    private let checkpointInterval: Int64
    private let checkpoint: @Sendable (DownloadCheckpoint) -> Void
    private let progress: @Sendable (TransferProgress) -> Void

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var isCancelled = false

    /// Where the current request asked the body to start; 0 without `Range`.
    private var requestedOffset: Int64 = 0
    private var file: FileHandle?
    private var written: Int64 = 0
    private var committed: Int64 = 0
    private var expected: Int64 = 0
    private var validator = DownloadValidator.none
    private var failure: (any Error)?
    /// Set when the server can't continue the file: the request is repeated without `Range`.
    private var restartFromZero = false

    init(
        url: URL, destination: URL, resume: ResumePoint?, checkpointInterval: Int64,
        checkpoint: @escaping @Sendable (DownloadCheckpoint) -> Void,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) {
        self.url = url
        self.destination = destination
        self.resume = resume
        self.checkpointInterval = checkpointInterval
        self.checkpoint = checkpoint
        self.progress = progress
    }

    func start(in session: URLSession, continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        session.delegateQueue.addOperation { self.send(in: session, resuming: self.resume) }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func send(in session: URLSession, resuming resume: ResumePoint?) {
        var request = URLRequest(url: url)
        requestedOffset = 0
        if let resume, resume.expectedLength > 0 {
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64 ?? 0
            // A complete file still asks for its last byte, so the server confirms it is the same file.
            let offset = min(size, resume.committedLength, resume.expectedLength - 1)
            if offset > 0 {
                requestedOffset = offset
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                switch resume.validator {
                case .etag(let value), .lastModified(let value): request.setValue(value, forHTTPHeaderField: "If-Range")
                case .none: break
                }
            }
        }
        let task = session.dataTask(with: request)
        lock.lock()
        self.task = task
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { task.cancel() } else { task.resume() }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failure = ExporterError.download("Not an HTTP response")
            return completionHandler(.cancel)
        }
        let validator = Self.validator(of: http)
        do {
            switch http.statusCode {
            case 206 where requestedOffset > 0:
                guard let resume, let range = ContentRange(http.value(forHTTPHeaderField: "Content-Range")),
                      range.start == requestedOffset, range.total == resume.expectedLength,
                      resume.validator == .none || validator == resume.validator
                else {
                    restartFromZero = true
                    return completionHandler(.cancel)
                }
                let file = try FileHandle(forWritingTo: destination)
                try file.truncate(atOffset: UInt64(requestedOffset))
                try file.seekToEnd()
                self.file = file
                (written, expected) = (requestedOffset, range.total)
            case 416 where requestedOffset > 0:
                restartFromZero = true
                return completionHandler(.cancel)
            case 200, 201, 203:
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw ExporterError.fileSystem("Could not create \(destination.lastPathComponent).")
                }
                file = try FileHandle(forWritingTo: destination)
                (written, expected) = (0, max(http.expectedContentLength, 0))
            default:
                failure = ExporterError.download("HTTP \(http.statusCode)")
                return completionHandler(.cancel)
            }
        } catch {
            failure = ExporterError.fileSystem("Could not save download: \(error.localizedDescription)")
            return completionHandler(.cancel)
        }
        self.validator = validator
        committed = written
        checkpoint(DownloadCheckpoint(expectedLength: expected, validator: validator, committedLength: committed))
        reportProgress()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let file, failure == nil else { return }
        do {
            try file.write(contentsOf: data)
        } catch {
            failure = ExporterError.fileSystem("Could not save download: \(error.localizedDescription)")
            dataTask.cancel()
            return
        }
        written += Int64(data.count)
        reportProgress()
        if written - committed >= checkpointInterval { flush() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        flush()
        try? file?.close()
        file = nil

        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if restartFromZero && !cancelled && failure == nil {
            restartFromZero = false
            send(in: session, resuming: nil)
            return
        }

        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        if cancelled {
            continuation?.resume(throwing: ExporterError.cancelled)
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: ExporterError.download(error.localizedDescription))
        } else if expected > 0, written != expected {
            continuation?.resume(throwing: ExporterError.download("Received \(written) of \(expected) bytes"))
        } else {
            progress(TransferProgress(bytesReceived: written, bytesExpected: expected > 0 ? expected : written))
            continuation?.resume()
        }
    }

    /// Makes the written bytes durable, then reports them as committed.
    private func flush() {
        guard let file, written > committed else { return }
        do {
            try file.synchronize()
        } catch {
            return
        }
        committed = written
        checkpoint(DownloadCheckpoint(expectedLength: expected, validator: validator, committedLength: committed))
    }

    private func reportProgress() {
        guard expected > 0 else { return }
        progress(TransferProgress(bytesReceived: written, bytesExpected: expected))
    }

    /// A strong ETag, else Last-Modified. A weak ETag can't be used with `If-Range`.
    private static func validator(of response: HTTPURLResponse) -> DownloadValidator {
        if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") { return .etag(etag) }
        if let date = response.value(forHTTPHeaderField: "Last-Modified") { return .lastModified(date) }
        return .none
    }
}

/// `Content-Range: bytes <start>-<end>/<total>`; nil for any other form, such as an unknown total.
struct ContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64

    init?(_ header: String?) {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst("bytes ".count).split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1]) else { return nil }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start <= end, end < total
        else { return nil }
        (self.start, self.end, self.total) = (start, end, total)
    }
}
