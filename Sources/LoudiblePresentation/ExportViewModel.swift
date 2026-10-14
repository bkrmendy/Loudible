import Foundation
import Observation
import LoudibleCore

/// Download and export jobs, their progress, and cancellation.
@MainActor
@Observable
public final class ExportViewModel {
    /// Where exported M4B files go: the downloads folder, next to the encrypted files.
    public let exportFolder: URL
    public private(set) var snapshot = ExportQueue.Snapshot()
    public var errorMessage: String?
    /// The failure of each book's latest attempt, by ASIN. Survives the queue dropping finished
    /// jobs, and is cleared when the book's next attempt starts.
    public private(set) var failures: [String: (kind: ExportJob.Kind, message: String)] = [:]
    /// Called whenever another job finishes, e.g. to rescan the folders.
    @ObservationIgnored public var onJobFinished: (@MainActor () -> Void)?

    private let queue: ExportQueue
    @ObservationIgnored private var observation: Task<Void, Never>?

    public init(queue: ExportQueue, exportFolder: URL) {
        self.queue = queue
        self.exportFolder = exportFolder
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
    public var activeJobCount: Int { jobs.filter { !$0.state.isFinished }.count }

    /// Shown above the library while jobs wait for the user to sign in again.
    public var notice: String? {
        isWaitingForAuthentication ? "Paused: sign in to Audible to continue." : nil
    }

    /// The book's most recent job, finished or not.
    public func latestJob(for asin: String) -> ExportJob? {
        jobs.last { $0.book.asin == asin }
    }

    // MARK: Actions

    /// Exports one book, whatever else is running.
    public func exportOne(_ book: Audiobook) async {
        await export([book])
    }

    /// Exports books to M4B, downloading the ones not downloaded yet.
    public func export(_ books: [Audiobook]) async {
        await enqueue(books, kind: .export)
    }

    /// Downloads books and keeps the encrypted files.
    public func download(_ books: [Audiobook]) async {
        await enqueue(books, kind: .download)
    }

    private func enqueue(_ books: [Audiobook], kind: ExportJob.Kind) async {
        errorMessage = nil
        do {
            try await queue.enqueue(books, kind: kind, exportDestination: exportFolder)
            apply(await queue.currentSnapshot)
        } catch {
            switch error {
            case .destinationUnavailable(let path):
                errorMessage = "The download folder could not be created or is not writable: \(path)"
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
    public func cancel(jobID: UUID) async {
        await queue.cancel(jobID)
    }

    public func resumeAfterAuthentication() async {
        await queue.resumeAfterAuthentication()
    }
}
