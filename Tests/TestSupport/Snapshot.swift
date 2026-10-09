import AppKit
import Foundation
import SwiftUI
@testable import AudibleExporterApp

/// Renders every `PreviewState` (the states the `#Preview`s show) into one PNG each.
///
/// SwiftUI controls on macOS are AppKit views that only draw inside a window, so each state gets
/// a real window. The window is never shown: its captures match a visible window's byte for byte.
/// It still needs a logged-in macOS session. `ImageRenderer` needs no window but draws pickers,
/// text fields, lists, and progress bars as "unsupported" placeholders.
///
/// Known limitation: `cacheDisplay` captures nothing at all while the Export button has its
/// accent-tinted Liquid Glass (`exportButtonReady`, `exportButtonRunning`, and any window with a
/// selection or running jobs). Capturing the layer tree or showing the window does not help.
@MainActor
public enum Snapshot {
    /// Writes `<folder>/<state>.png` for each state, or only for those named in `states`.
    /// Returns the files written.
    @discardableResult
    public static func run(to folder: URL, states names: Set<String>? = nil) async throws -> [URL] {
        if let names {
            let unknown = names.subtracting(PreviewState.allCases.map(\.rawValue))
            guard unknown.isEmpty else { throw UnknownStates(names: unknown.sorted()) }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var written: [URL] = []
        for state in PreviewState.allCases where names?.contains(state.rawValue) ?? true {
            let url = folder.appendingPathComponent("\(state.rawValue).png")
            try await render(state).write(to: url)
            written.append(url)
        }
        return written
    }

    public struct UnknownStates: Error, CustomStringConvertible {
        public let names: [String]
        public var description: String {
            "Unknown preview states: \(names.joined(separator: ", ")). Valid: \(PreviewState.allCases.map(\.rawValue).joined(separator: ", "))"
        }
    }

    private static func render(_ state: PreviewState) async throws -> Data {
        let size = PreviewCatalog.size(state)
        let isWindow = state.rawValue.hasPrefix("window")
        // Whole-window states get the real window chrome and toolbar; components a plain window.
        let style: NSWindow.StyleMask = isWindow ? [.titled, .closable, .resizable, .fullSizeContentView] : [.titled]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        // Closing must not release the window a second time; Swift owns it.
        window.isReleasedWhenClosed = false
        window.title = "AudibleExporter"
        window.contentView = NSHostingView(rootView: PreviewCatalog.view(state))
        defer { window.close() }

        let view = isWindow ? window.contentView!.superview! : window.contentView!
        return try await stableCapture(of: view)
    }

    /// Captures `view` until two captures in a row match, so covers (`AsyncImage`) and loaded
    /// data have arrived. Spinners never settle; those states take the capture at the timeout.
    private static func stableCapture(of view: NSView, timeout: Duration = .seconds(4)) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        try await Task.sleep(for: .milliseconds(150))
        var previous = try capture(view)
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(150))
            let current = try capture(view)
            if current == previous { return current }
            previous = current
        }
        return previous
    }

    private static func capture(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureFailed() }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CaptureFailed() }
        return png
    }

    private struct CaptureFailed: Error {}
}
