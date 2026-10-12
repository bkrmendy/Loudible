import Foundation
import Observation
import LoudibleCore

/// Export folder, download and export jobs, progress, and cancellation.
@MainActor
@Observable
public final class ExportViewModel {
    public var destinationFolder: URL?
    public private(set) var snapshot = ExportQueue.Snapshot()
    public var errorMessage: String?
    /// The failure of each book's latest attempt, by ASIN. Survives the queue dropping finished
    /// jobs, and is cleared when the book's next attempt starts.
    public private(set) var failures: [String: (kind: ExportJob.Kind, message: String)] = [:]
    /// Called whenever another job finishes, e.g. to rescan the folders.
    @ObservationIgnored public var onJobFinished: (@MainActor () -> Void)?

    private let queue: ExportQueue
    @ObservationIgnored private var observation: Task<Void, Never>?

    public init(queue: ExportQueue, destinationFolder: URL? = nil) {
        self.queue = queue
        self.destinationFolder = destinationFolder
    }

    /// Starts mirroring the queue's progress.
    public func start() async {
        guard observation == nil else { return }
        let updates = await queue.updates()
        observation = Task { [weak self] in
            for await snapshot in updates {
                self?.apply(snapshot)
            }
        }
    }

    private func apply(_ new: ExportQueue.Snapshot) {
        let finishedBefore = snapshot.jobs.filter(\.state.isFinished).count
        snapshot = new
        // The last job of each book in the list decides whether it is failed.
        var latest: [String: ExportJob] = [:]
        for job in new.jobs { latest[job.book.asin] = job }
        for (asin, job) in latest {
            if case .failed(let message) = job.state {
                failures[asin] = (job.kind, Self.reason(message, title: job.book.title))
            } else if failures[asin] != nil {
                failures[asin] = nil
            }
        }
        if new.jobs.filter(\.state.isFinished).count > finishedBefore { onJobFinished?() }
    }

    /// Job failures read "Title: reason"; next to the book the title is redundant.
    private static func reason(_ message: String, title: String) -> String {
        message.hasPrefix("\(title): ") ? String(message.dropFirst(title.count + 2)) : message
    }

    // MARK: Derived state

    public var jobs: [ExportJob] { snapshot.jobs }
    public var isRunning: Bool { snapshot.isRunning }
    public var isWaitingForAuthentication: Bool { snapshot.isWaitingForAuthentication }
    public var fractionCompleted: Double { snapshot.fractionCompleted }
    public var canChooseFolder: Bool { !isRunning }
    public var canCancel: Bool { isRunning }
    public var activeJobCount: Int { jobs.filter { !$0.state.isFinished }.count }

    /// Whether `job` can still be cancelled on its own.
    public func canCancel(_ job: ExportJob) -> Bool {
        isRunning && !job.state.isFinished
    }

    public func canExport(_ books: [Audiobook], isSignedIn: Bool) -> Bool {
        isSignedIn && !books.isEmpty && destinationFolder != nil && !isRunning
    }

    /// The book's most recent job, finished or not.
    public func latestJob(for asin: String) -> ExportJob? {
        jobs.last { $0.book.asin == asin }
    }

    private var activeKinds: Set<ExportJob.Kind> {
        Set(jobs.filter { !$0.state.isFinished }.map(\.kind))
    }

    /// The toolbar's word for what is running: "Downloading", "Exporting", or "Working" for a mix.
    public var activityTitle: String {
        switch activeKinds {
        case [.download]: "Downloading"
        case [.export], []: "Exporting"
        default: "Working"
        }
    }

    public var statusText: String? {
        guard !jobs.isEmpty else { return nil }
        if isWaitingForAuthentication { return "Paused: sign in to Audible to continue." }
        let finished = jobs.filter(\.state.isFinished).count
        if isRunning {
            let verb = switch activeKinds {
            case [.download]: "Downloading"
            case [.export], []: "Exporting"
            default: "Working on"
            }
            return "\(verb) \(min(finished + 1, jobs.count)) of \(jobs.count)…"
        }
        func count(_ kind: ExportJob.Kind) -> Int {
            jobs.filter { $0.kind == kind && { if case .completed = $0.state { true } else { false } }($0) }.count
        }
        let failed = jobs.filter { if case .failed = $0.state { true } else { false } }.count
        let cancelled = jobs.filter { $0.state == .cancelled }.count
        var parts: [String] = []
        if count(.download) > 0 { parts.append("\(count(.download)) downloaded") }
        if count(.export) > 0 || parts.isEmpty { parts.append("\(count(.export)) exported") }
        if failed > 0 { parts.append("\(failed) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return parts.joined(separator: ", ")
    }

    // MARK: Actions

    public func export(_ books: [Audiobook], isSignedIn: Bool) async {
        guard canExport(books, isSignedIn: isSignedIn) else { return }
        await enqueue(books, kind: .export)
    }

    /// Exports one book, whatever else is running.
    public func exportOne(_ book: Audiobook) async {
        guard destinationFolder != nil else { return }
        await enqueue([book], kind: .export)
    }

    /// Downloads books and keeps the encrypted files.
    public func download(_ books: [Audiobook]) async {
        await enqueue(books, kind: .download)
    }

    private func enqueue(_ books: [Audiobook], kind: ExportJob.Kind) async {
        errorMessage = nil
        do {
            try await queue.enqueue(books, kind: kind, exportDestination: destinationFolder)
            apply(await queue.currentSnapshot)
        } catch {
            switch error {
            case .destinationUnavailable(let path):
                errorMessage = kind == .download
                    ? "The download folder could not be created or is not writable: \(path)"
                    : "The export folder is not available or not writable: \(path)"
            case .nothingToExport:
                errorMessage = "Select at least one book to export."
            }
        }
    }

    /// Cancels every job and removes them all from the list, completed ones included.
    public func cancel() async {
        await queue.cancel()
        await queue.waitUntilFinished()
        await queue.clear()
        apply(await queue.currentSnapshot)
    }

    /// Cancels one job; the others continue.
    public func cancel(_ job: ExportJob) async {
        await cancel(jobID: job.id)
    }

    public func cancel(jobID: UUID) async {
        await queue.cancel(jobID)
    }

    public func resumeAfterAuthentication() async {
        await queue.resumeAfterAuthentication()
    }
}
