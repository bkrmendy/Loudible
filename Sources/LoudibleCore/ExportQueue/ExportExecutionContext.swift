import Foundation

/// Progress events carry identity so delayed adapter callbacks cannot affect later transfers.
enum ExportProgressEvent: Sendable {
    case phase(ExportJob.Phase)
    case beginDownload(UUID)
    case download(UUID, DownloadProgress)
    case endDownload(UUID)
    case conversion(Double)
}

/// Application callbacks needed by a workflow, independent of any queue implementation.
struct ExportExecutionContext: Sendable {
    let report: @Sendable (ExportProgressEvent) async -> Void
    let keepsRecovery: @Sendable () async -> Bool

    func phase(_ phase: ExportJob.Phase) async { await report(.phase(phase)) }

    func checkCancellation() throws(ExporterError) {
        if Task.isCancelled { throw .cancelled }
    }
}
