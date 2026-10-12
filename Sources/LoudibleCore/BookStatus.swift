import Foundation

/// The one status shown on a book's cover. When several apply, the most relevant wins:
/// running > queued > failed > exported > downloaded > none.
public enum BookStatus: Sendable, Equatable {
    case none
    /// Queued, or paused for sign-in.
    case queued(ExportJob.Kind)
    /// `progress` is the job's overall completion (0...1).
    case running(ExportJob.Kind, progress: Double)
    /// The latest attempt failed. Kept in memory only; cleared when the next attempt starts.
    case failed(ExportJob.Kind, String)
    case downloaded
    case exported

    /// - Parameters:
    ///   - jobs: the queue's jobs; only unfinished jobs of `asin` are considered.
    ///   - failure: the failure of the book's latest attempt, if it failed.
    public static func resolve(
        asin: String,
        jobs: [ExportJob],
        failure: (kind: ExportJob.Kind, message: String)?,
        isDownloaded: Bool,
        isExported: Bool
    ) -> BookStatus {
        let active = jobs.filter { $0.book.asin == asin && !$0.state.isFinished }
        if let job = active.first(where: { if case .running = $0.state { true } else { false } }) {
            return .running(job.kind, progress: job.fractionCompleted)
        }
        if let job = active.first {
            return .queued(job.kind)
        }
        if let failure { return .failed(failure.kind, failure.message) }
        if isExported { return .exported }
        if isDownloaded { return .downloaded }
        return .none
    }
}

/// Something the user can do to one book from its menu.
public enum BookAction: Sendable, Hashable {
    case download
    case cancel(jobID: UUID, kind: ExportJob.Kind)
    case export
    case showDownload
    case showExport
    case deleteDownload
}

/// A menu entry: shown items only, with a reason when it is disabled.
public struct BookMenuItem: Sendable, Equatable, Identifiable {
    public var id: BookAction { action }
    public let action: BookAction
    public let isEnabled: Bool
    public let disabledReason: String?

    public init(_ action: BookAction, isEnabled: Bool = true, disabledReason: String? = nil) {
        self.action = action
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
    }
}

/// Which menu items a book offers. Items that don't apply are left out, except Export, which is
/// disabled with a reason.
public enum BookMenu {
    public struct Context: Sendable, Equatable {
        public var isDownloaded: Bool
        public var isExported: Bool
        public var isInLibrary: Bool
        public var hasManifest: Bool
        public var hasExportFolder: Bool
        public var isSignedIn: Bool

        public init(
            isDownloaded: Bool, isExported: Bool, isInLibrary: Bool,
            hasManifest: Bool, hasExportFolder: Bool, isSignedIn: Bool
        ) {
            self.isDownloaded = isDownloaded
            self.isExported = isExported
            self.isInLibrary = isInLibrary
            self.hasManifest = hasManifest
            self.hasExportFolder = hasExportFolder
            self.isSignedIn = isSignedIn
        }
    }

    /// - Parameter jobs: the queue's jobs; only unfinished jobs of `asin` are considered.
    public static func items(asin: String, jobs: [ExportJob], context: Context) -> [BookMenuItem] {
        let active = jobs.filter { $0.book.asin == asin && !$0.state.isFinished }
        var items: [BookMenuItem] = []
        if !context.isDownloaded && context.isInLibrary && active.isEmpty {
            items.append(BookMenuItem(.download))
        }
        for job in active {
            items.append(BookMenuItem(.cancel(jobID: job.id, kind: job.kind)))
        }
        if context.isDownloaded {
            let reason = exportBlocker(hasActiveJob: !active.isEmpty, context: context)
            items.append(BookMenuItem(.export, isEnabled: reason == nil, disabledReason: reason))
            items.append(BookMenuItem(.showDownload))
        }
        if context.isExported {
            items.append(BookMenuItem(.showExport))
        }
        if context.isDownloaded && active.isEmpty {
            items.append(BookMenuItem(.deleteDownload))
        }
        return items
    }

    private static func exportBlocker(hasActiveJob: Bool, context: Context) -> String? {
        // Exporting books that have left the library is out of scope.
        if !context.isInLibrary { return "This book is no longer in your library." }
        if !context.hasExportFolder { return "Choose an export folder first." }
        if hasActiveJob { return "This book is already being downloaded or exported." }
        if !context.hasManifest && !context.isSignedIn {
            return "Sign in to Audible to get the keys for this download."
        }
        return nil
    }
}
