import AppKit
import Foundation
import SwiftUI
@testable import LoudibleApp

/// Renders the examples declared beside each view into PNGs, without launching Loudible.
///
/// SwiftUI controls on macOS are AppKit views that only draw inside a window, so each state gets
/// a real window. The window is never shown: its captures match a visible window's byte for byte.
/// It still needs a logged-in macOS session. `ImageRenderer` needs no window but draws pickers,
/// text fields, lists, and progress bars as "unsupported" placeholders.
@MainActor
public enum Snapshot {
    /// Writes `<folder>/<state>.png` for each state, or only for those named in `states`.
    /// Returns the files written.
    @discardableResult
    public static func run(to folder: URL, states names: Set<String>? = nil) async throws -> [URL] {
        let previews = try selected(states: names)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        for preview in previews {
            let url = folder.appendingPathComponent("\(preview.id).png")
            try await render(preview).write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }

    /// Generates one HTML gallery and an images folder per Swift file, beside its source by default.
    public static func galleries(to root: URL? = nil, file: String? = nil, states: Set<String>? = nil) async throws {
        let previews = try selected(file: file, states: states)
        let groups = Dictionary(grouping: previews, by: \.source)
        for source in groups.keys.sorted(by: { $0.path < $1.path }) {
            let examples = groups[source]!
            let folder = PreviewGallery.folder(for: source, root: root)
            let images = folder.appendingPathComponent("images", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            for preview in examples {
                let image = images.appendingPathComponent("\(preview.id).png")
                try await render(preview).write(to: image, options: .atomic)
                print("Rendered \(image.path)")
            }
            let html = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)Preview.html")
            try PreviewGallery.html(source: source, previews: examples)
                .write(to: html, atomically: true, encoding: .utf8)
            print("Gallery: \(html.path)")
        }
    }

    /// Lists registered examples without creating windows or writing files.
    public static func list() {
        for preview in ViewPreviews.all {
            print("\(preview.source.lastPathComponent)\t\(preview.id)\t\(preview.title)")
        }
    }

    static func selected(file: String? = nil, states: Set<String>? = nil) throws -> [ViewPreview] {
        let previews = ViewPreviews.all.filter { file == nil || $0.source.lastPathComponent == file }
        guard !previews.isEmpty else { throw SelectionError(message: "Unknown preview file: \(file ?? "")") }
        if let states {
            let unknown = states.subtracting(previews.map(\.id))
            guard unknown.isEmpty else {
                throw SelectionError(message: "Unknown preview states: \(unknown.sorted().joined(separator: ", "))")
            }
        }
        let selected = previews.filter { states?.contains($0.id) ?? true }
        guard !selected.isEmpty else { throw SelectionError(message: "No preview states selected") }
        return selected
    }

    private struct SelectionError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func render(_ preview: ViewPreview) async throws -> Data {
        let size = preview.size
        let isWindow = preview.windowChrome
        // Whole-window states get the real window chrome and toolbar; components a plain window.
        let style: NSWindow.StyleMask = isWindow ? [.titled, .closable, .resizable, .fullSizeContentView] : [.titled]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false)
        // Closing must not release the window a second time; Swift owns it.
        window.isReleasedWhenClosed = false
        window.title = "Loudible"
        window.contentView = NSHostingView(rootView: preview.content())
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
