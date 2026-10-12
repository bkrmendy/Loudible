import Foundation
import LoudibleCore

extension BookStatus {
    /// What VoiceOver reads as the book's value, also the badge tooltip. Nil when there is no badge.
    public var accessibilityText: String? {
        switch self {
        case .none:
            nil
        case .queued(let kind):
            kind == .download ? "Queued for download" : "Queued for export"
        case .running(let kind, let progress):
            "\(kind == .download ? "Downloading" : "Exporting"), \(Int((progress * 100).rounded(.down))) percent"
        case .failed(let kind, let reason):
            // Some reasons already say what failed ("Download failed: HTTP 500").
            reason.localizedCaseInsensitiveContains("failed:")
                ? reason
                : "\(kind == .download ? "Download" : "Export") failed: \(reason)"
        case .downloaded:
            "Downloaded"
        case .exported:
            "Exported to M4B"
        }
    }
}
