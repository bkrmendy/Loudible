import Foundation
import LoudibleScheduling

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
    public enum StartError: Error, Equatable {
        case nothingToExport
        case destinationUnavailable(String)
    }

    private let downloads: LocalDownloads
    private let download: DownloadWorkflow
    private let exporter: BookExportWorkflow
    private var scheduler: KeyedScheduler<UUID, String>
    private var state = ExportQueueState()
    private var running: [UUID: Task<Void, Never>] = [:]
    private var exportDestinations: [UUID: URL] = [:]
    private var authenticationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var suspended: Set<UUID> = []
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
        let licenses = LicenseProvider(auth: auth, api: api)
        let finalizer = ExportFileFinalizer()
        let download = DownloadWorkflow(licenses: licenses, downloader: downloader, downloads: downloads,
            finalizer: finalizer)
        self.downloads = downloads
        self.download = download
        self.exporter = BookExportWorkflow(download: download, converter: converter, finalizer: finalizer)
        self.scheduler = KeyedScheduler(maximumConcurrent: maximumConcurrentBooks)
    }

    public var currentSnapshot: Snapshot { state.snapshot }

    /// Emits the current snapshot, then every change.
    public func updates() -> AsyncStream<Snapshot> {
        let id = UUID()
        return state.updates(id: id) { [weak self] in
            Task { await self?.removeObserver(id) }
        }
    }

    private func removeObserver(_ id: UUID) { state.removeObserver(id) }

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
            guard FileManager.default.fileExists(atPath: exportDestination.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  FileManager.default.isWritableFile(atPath: exportDestination.path)
            else { throw .destinationUnavailable(exportDestination.path) }
        }

        // A new run starts with a clean list; finished jobs of the last run are dropped.
        if !state.snapshot.isRunning {
            state.snapshot.jobs.removeAll()
            exportDestinations.removeAll()
        }
        let pending = state.snapshot.jobs.filter { !$0.state.isFinished }
        var added: [UUID] = []
        for book in unique {
            let covered = pending.contains { job in
                job.book.asin == book.asin && (job.kind == kind || (kind == .download && job.kind == .export))
            }
            guard !covered else { continue }
            let job = ExportJob(book: book, kind: kind)
            state.snapshot.jobs.append(job)
            scheduler.enqueue(id: job.id, key: book.asin)
            if kind == .export { exportDestinations[job.id] = exportDestination }
            added.append(job.id)
        }
        if !added.isEmpty { state.snapshot.isRunning = true }
        schedule()
        return added
    }

    /// Cancels every running and queued job. Completed ones are kept.
    public func cancel() {
        for entry in scheduler.removeAllPending() { state.update(entry.id, to: .cancelled) }
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
        } else if scheduler.removePending(id: id) {
            state.update(id, to: .cancelled)
            schedule()
        }
    }

    /// Forgets the jobs of a finished run. Ignored while jobs are running.
    public func clear() {
        guard !state.snapshot.isRunning else { return }
        state.snapshot = Snapshot()
        exportDestinations.removeAll()
    }

    /// Continues every job paused for sign-in.
    public func resumeAfterAuthentication() {
        let waiters = authenticationWaiters.values
        authenticationWaiters.removeAll()
        state.snapshot.isWaitingForAuthentication = false
        scheduler.setPaused(false)
        waiters.forEach { $0.resume() }
        schedule()
    }

    /// Waits until no job is queued or running.
    public func waitUntilFinished() async {
        guard state.snapshot.isRunning else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    // MARK: Scheduling

    private func schedule() {
        for entry in scheduler.reserveReady() {
            let id = entry.id
            running[id] = Task {
                await self.process(id)
                self.jobEnded(id)
            }
        }
        finishIfIdle()
    }

    private func jobEnded(_ id: UUID) {
        running[id] = nil
        scheduler.finish(id: id)
        suspended.remove(id)
        exportDestinations[id] = nil
        schedule()
    }

    private func finishIfIdle() {
        guard state.snapshot.isRunning, running.isEmpty, scheduler.isIdle else { return }
        state.snapshot.isRunning = false
        state.snapshot.isWaitingForAuthentication = false
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func process(_ id: UUID) async {
        guard let index = state.index(of: id) else { return }
        let job = state.snapshot.jobs[index]
        while true {
            do {
                let output = try await runOnce(id, job: job)
                state.update(id, to: .completed(output))
                return
            } catch .authenticationRequired {
                state.update(id, to: .waitingForAuthentication)
                await waitForAuthentication(id)
                if Task.isCancelled {
                    state.update(id, to: .cancelled)
                    return
                }
                // A paused job restarts from licensing, whatever phase it then skips to.
                state.update(id, to: .running(.licensing, progress: 0))
            } catch .cancelled {
                state.update(id, to: .cancelled)
                return
            } catch {
                if Task.isCancelled {
                    state.update(id, to: .cancelled)
                } else {
                    state.update(id, to: .failed("\(job.book.title): \(error.localizedDescription)"))
                }
                return
            }
        }
    }

    private func runOnce(_ id: UUID, job: ExportJob) async throws(ExporterError) -> URL {
        if Task.isCancelled { throw .cancelled }
        let context = ExportExecutionContext(
            report: { [weak self] event in await self?.report(id, event: event) },
            keepsRecovery: { [weak self] in await self?.keepsRecovery(id) ?? false })
        switch job.kind {
        case .download:
            return try await download.run(book: job.book, kind: .download, context: context).input
        case .export:
            guard let destination = exportDestinations[id] else { throw .unexpected("No export folder.") }
            return try await exporter.run(book: job.book, destination: destination, context: context)
        }
    }

    private func report(_ id: UUID, event: ExportProgressEvent) { state.report(id, event: event) }
    private func keepsRecovery(_ id: UUID) -> Bool { suspended.contains(id) }

    // MARK: Authentication pause

    private func waitForAuthentication(_ id: UUID) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    authenticationWaiters[id] = continuation
                    state.snapshot.isWaitingForAuthentication = true
                    scheduler.setPaused(true)
                }
            }
        } onCancel: {
            Task { await self.wakeAuthenticationWaiter(id) }
        }
    }

    private func wakeAuthenticationWaiter(_ id: UUID) {
        authenticationWaiters.removeValue(forKey: id)?.resume()
        if authenticationWaiters.isEmpty {
            state.snapshot.isWaitingForAuthentication = false
            scheduler.setPaused(false)
            schedule()
        }
    }
}
