import Foundation

/// Progress of one download or export of one audiobook. State changes go through
/// `transition(to:)`, which rejects moves the queue must never make (for example, leaving a
/// finished state).
public struct ExportJob: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Hashable {
        /// Fetch and keep the encrypted file.
        case download
        /// Convert to M4B, downloading first if the book is not downloaded yet.
        case export
    }

    public enum Phase: Int, Sendable, Comparable, CaseIterable {
        case licensing
        case downloading
        case converting
        case finalizing

        public static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum State: Sendable, Equatable {
        case queued
        /// `progress` is the fraction (0...1) of the current phase.
        case running(Phase, progress: Double)
        /// Paused until the user signs in again; the job restarts from licensing.
        case waitingForAuthentication
        case completed(URL)
        case failed(String)
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .completed, .failed, .cancelled: true
            case .queued, .running, .waitingForAuthentication: false
            }
        }
    }

    public struct InvalidTransition: Error, Equatable {
        public let from: State
        public let to: State
    }

    /// Unique per job: one book can have a download and an export job at the same time.
    public let id: UUID
    public let kind: Kind
    public let book: Audiobook
    public private(set) var state: State
    /// The phase the job started in. An export of a downloaded book starts at `.converting`, and
    /// its progress is measured from there.
    public private(set) var firstPhase: Phase?
    /// Bytes of the audio download so far; only while in `.downloading` and once its size is known.
    public private(set) var transferred: TransferProgress?

    public init(book: Audiobook, kind: Kind = .export, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.book = book
        self.state = .queued
    }

    /// - Parameter transferred: the byte count behind a `.downloading` state; ignored otherwise.
    public mutating func transition(to newState: State,
                                    transferred: TransferProgress? = nil) throws(InvalidTransition) {
        guard Self.allows(from: state, to: newState) else {
            throw InvalidTransition(from: state, to: newState)
        }
        if firstPhase == nil, case .running(let phase, _) = newState { firstPhase = phase }
        state = newState
        if case .running(.downloading, _) = newState { self.transferred = transferred } else { self.transferred = nil }
    }

    /// Only an identified new transfer attempt may reset progress within downloading.
    mutating func restartDownload() {
        guard case .running(.downloading, _) = state else { return }
        state = .running(.downloading, progress: 0)
        transferred = nil
    }

    static func allows(from old: State, to new: State) -> Bool {
        switch (old, new) {
        case (.completed, _), (.failed, _), (.cancelled, _):
            return false
        // Work already done (a kept download, stored keys) lets a job start in any phase.
        case (.queued, .running),
             (.queued, .waitingForAuthentication),
             (.queued, .failed),
             (.queued, .cancelled):
            return true
        case let (.running(oldPhase, oldProgress), .running(newPhase, newProgress)):
            // Phases only move forward; progress within a phase never goes backwards.
            return newPhase > oldPhase || (newPhase == oldPhase && newProgress >= oldProgress)
        case (.running, .waitingForAuthentication),
             (.running, .completed),
             (.running, .failed),
             (.running, .cancelled):
            return true
        case (.waitingForAuthentication, .running(.licensing, _)),
             (.waitingForAuthentication, .failed),
             (.waitingForAuthentication, .cancelled):
            return true
        default:
            return false
        }
    }

    /// Overall completion of this job (0...1), weighting download and conversion most and
    /// counting only the phases from `firstPhase` on.
    public var fractionCompleted: Double {
        switch state {
        case .queued, .waitingForAuthentication, .failed, .cancelled:
            return 0
        case .completed:
            return 1
        case .running(let phase, let progress):
            let (starts, weights) = kind == .download
                ? (Self.downloadPhaseStart, Self.downloadPhaseWeight)
                : (Self.exportPhaseStart, Self.exportPhaseWeight)
            let raw = starts[phase]! + weights[phase]! * min(max(progress, 0), 1)
            let origin = starts[firstPhase ?? .licensing]!
            return origin < 1 ? max(0, (raw - origin) / (1 - origin)) : raw
        }
    }

    private static let exportPhaseWeight: [Phase: Double] = [
        .licensing: 0.02,
        .downloading: 0.58,
        .converting: 0.38,
        .finalizing: 0.02
    ]
    private static let exportPhaseStart: [Phase: Double] = [
        .licensing: 0,
        .downloading: 0.02,
        .converting: 0.60,
        .finalizing: 0.98
    ]
    // A download never converts; `.converting` is given no weight.
    private static let downloadPhaseWeight: [Phase: Double] = [
        .licensing: 0.02,
        .downloading: 0.96,
        .converting: 0,
        .finalizing: 0.02
    ]
    private static let downloadPhaseStart: [Phase: Double] = [
        .licensing: 0,
        .downloading: 0.02,
        .converting: 0.98,
        .finalizing: 0.98
    ]
}
