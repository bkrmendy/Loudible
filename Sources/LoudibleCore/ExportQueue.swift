import Foundation

/// Schedules downloads and exports.
///
/// - A **download** fetches the encrypted file (license → download → manifest → move into place)
///   and keeps it in `LocalDownloads.folder`.
/// - An **export** converts the kept file to M4B. A book that is not downloaded yet is downloaded
///   first, exactly as a download job would, and the file is kept.
///
/// Jobs for one book run strictly in the order they were queued; up to `maximumConcurrentBooks`
/// different books run at once. Work can be added while jobs run. A failed job does not stop the
/// others, and finished files are never touched again. When Audible requires a new sign-in, the
/// affected jobs pause until `resumeAfterAuthentication()` or `cancel()`, and no new job starts
/// meanwhile.
///
/// Failed or suspended downloads keep a `PartialDownload` recovery record; explicit cancellation
/// deletes it. Native resumption is best effort, with a fresh download as fallback.
public actor ExportQueue {
    public struct Snapshot: Sendable, Equatable {
        public var jobs: [ExportJob]
        public var isRunning: Bool
        public var isWaitingForAuthentication: Bool

        public init(jobs: [ExportJob] = [], isRunning: Bool = false, isWaitingForAuthentication: Bool = false) {
            self.jobs = jobs
            self.isRunning = isRunning
            self.isWaitingForAuthentication = isWaitingForAuthentication
        }

        /// Completion across all jobs (0...1).
        public var fractionCompleted: Double {
            guard !jobs.isEmpty else { return 0 }
            return jobs.map(\.fractionCompleted).reduce(0, +) / Double(jobs.count)
        }
    }

    public enum StartError: Error, Equatable {
        case nothingToExport
        case destinationUnavailable(String)
    }

    /// Appended to a conversion error when the input was a kept download, which may be damaged.
    static let redownloadHint = "If this keeps failing, delete the download and download it again."

    let auth: AuthenticationCoordinator
    let api: any AudibleAPI
    let downloader: any FileDownloader
    let converter: any AudioConverter
    let downloads: LocalDownloads
    private let maximumConcurrentBooks: Int
    let fileManager = FileManager.default

    var snapshot = Snapshot() {
        didSet {
            guard snapshot != oldValue else { return }
            for continuation in observers.values { continuation.yield(snapshot) }
        }
    }
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var running: [UUID: Task<Void, Never>] = [:]
    var exportDestinations: [UUID: URL] = [:]
    var authenticationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Running jobs stopped by `suspend()`: their downloads keep recovery state.
    var suspended: Set<UUID> = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - downloads: where downloads are kept, with their manifests.
    ///   - maximumConcurrentBooks: how many different books may be worked on at once.
    public init(
        auth: AuthenticationCoordinator,
        api: any AudibleAPI,
        downloader: any FileDownloader,
        converter: any AudioConverter,
        downloads: LocalDownloads,
        maximumConcurrentBooks: Int = 3
    ) {
        self.auth = auth
        self.api = api
        self.downloader = downloader
        self.converter = converter
        self.downloads = downloads
        self.maximumConcurrentBooks = max(1, maximumConcurrentBooks)
    }

    public var currentSnapshot: Snapshot { snapshot }

    /// Emits the current snapshot, then every change.
    public func updates() -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        observers[id] = continuation
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: Control

    /// Exports `books` into `destination`. Returns once the jobs are queued.
    public func start(_ books: [Audiobook], destination: URL) throws(StartError) {
        try enqueue(books, kind: .export, exportDestination: destination)
    }

    /// Queues one job of `kind` per book and returns the ids of the jobs it added. Books that
    /// already have an unfinished job of that kind are skipped, and so is a download of a book
    /// with an unfinished export, which downloads it anyway.
    /// - Parameter exportDestination: required for `.export`, ignored for `.download`.
    @discardableResult
    public func enqueue(
        _ books: [Audiobook],
        kind: ExportJob.Kind,
        exportDestination: URL?) throws(StartError) -> [UUID] {
        var seen = Set<String>()
        let unique = books.filter { seen.insert($0.asin).inserted }
        guard !unique.isEmpty else { throw .nothingToExport }

        // First, so an export destination that is the downloads folder exists before it is checked.
        do {
            try downloads.ensureFolder()
        } catch {
            throw .destinationUnavailable(downloads.folder.path)
        }
        if kind == .export {
            guard let exportDestination else { throw .destinationUnavailable("") }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: exportDestination.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.isWritableFile(atPath: exportDestination.path)
            else { throw .destinationUnavailable(exportDestination.path) }
        }

        // A new run starts with a clean list; finished jobs of the last run are dropped.
        if !snapshot.isRunning {
            snapshot.jobs.removeAll()
            exportDestinations.removeAll()
        }
        let pending = snapshot.jobs.filter { !$0.state.isFinished }
        var added: [UUID] = []
        for book in unique {
            let covered = pending.contains { job in
                job.book.asin == book.asin && (job.kind == kind || (kind == .download && job.kind == .export))
            }
            guard !covered else { continue }
            let job = ExportJob(book: book, kind: kind)
            snapshot.jobs.append(job)
            if kind == .export { exportDestinations[job.id] = exportDestination }
            added.append(job.id)
        }
        if !added.isEmpty { snapshot.isRunning = true }
        schedule()
        return added
    }

    /// Cancels every running and queued job. Completed ones are kept.
    public func cancel() {
        for index in snapshot.jobs.indices where snapshot.jobs[index].state == .queued {
            update(snapshot.jobs[index].id, to: .cancelled)
        }
        for task in running.values { task.cancel() }
        finishIfIdle()
    }

    /// Stops every job like `cancel()`, but keeps download recovery state to be
    /// resumed when possible by the next download. Used on quit or sign-out.
    public func suspend() {
        suspended.formUnion(running.keys)
        cancel()
    }

    /// Cancels one job: a running one stops, a queued one is skipped. Finished jobs and unknown
    /// ids are ignored.
    public func cancel(_ id: UUID) {
        if let task = running[id] {
            task.cancel()
        } else if let index = index(of: id), snapshot.jobs[index].state == .queued {
            update(id, to: .cancelled)
            schedule()
        }
    }

    /// Forgets the jobs of a finished run. Ignored while jobs are running.
    public func clear() {
        guard !snapshot.isRunning else { return }
        snapshot = Snapshot()
        exportDestinations.removeAll()
    }

    /// Continues every job paused for sign-in.
    public func resumeAfterAuthentication() {
        let waiters = authenticationWaiters.values
        authenticationWaiters.removeAll()
        snapshot.isWaitingForAuthentication = false
        waiters.forEach { $0.resume() }
        schedule()
    }

    /// Waits until no job is queued or running.
    public func waitUntilFinished() async {
        guard snapshot.isRunning else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    // MARK: Scheduling

    /// Starts queued jobs in order, one per book, while there is capacity and nobody waits for sign-in.
    func schedule() {
        defer { finishIfIdle() }
        guard !snapshot.isWaitingForAuthentication else { return }
        // A book is blocked once an earlier unfinished job of it is seen, so its jobs keep their order.
        var blocked = Set<String>()
        for job in snapshot.jobs where !job.state.isFinished {
            let asin = job.book.asin
            guard !blocked.contains(asin) else { continue }
            blocked.insert(asin)
            guard job.state == .queued, running[job.id] == nil, running.count < maximumConcurrentBooks else { continue }
            let id = job.id
            running[id] = Task {
                await self.process(id)
                self.jobEnded(id)
            }
        }
    }

    private func jobEnded(_ id: UUID) {
        running[id] = nil
        suspended.remove(id)
        exportDestinations[id] = nil
        schedule()
    }

    private func finishIfIdle() {
        guard snapshot.isRunning, running.isEmpty,
              !snapshot.jobs.contains(where: { !$0.state.isFinished }) else { return }
        snapshot.isRunning = false
        snapshot.isWaitingForAuthentication = false
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
