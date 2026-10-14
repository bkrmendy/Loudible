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
        case .running(let kind, let progress, let transferred):
            ["\(kind == .download ? "Downloading" : "Exporting")", "\(Int((progress * 100).rounded(.down))) percent",
             transferred.map { "\($0.receivedText) of \($0.expectedText)" }].compactMap { $0 }.joined(separator: ", ")
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

extension TransferProgress {
    /// "132 MB / 288 MB". Whole megabytes, so the text doesn't change width as decimals come and go.
    public var text: String { "\(receivedText) / \(expectedText)" }

    var receivedText: String { Self.format(bytesReceived) }
    var expectedText: String { Self.format(bytesExpected) }

    private static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = .useMB
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: bytes)
    }
}
