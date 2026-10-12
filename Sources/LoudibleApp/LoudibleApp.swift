import AppKit
import SwiftUI
import LoudibleAdapters
import LoudibleCore
import LoudibleFFmpeg
import LoudiblePresentation

/// The entry point of both app shells: `Sources/Loudible` for `swift run`, and the
/// Xcode project's app target.
public enum Launcher {
    @MainActor
    public static func main() {
        // Used by Scripts/verify-app.sh: proves the bundled FFmpeg loads, is LGPL, and is complete.
        if CommandLine.arguments.contains("--self-test") {
            let missing = FFmpegConverter.missingComponents
            print("Loudible self-test: libavformat \(FFmpegConverter.libavformatVersion)")
            print("license: \(FFmpegConverter.license)")
            print("missing components: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))")
            let isLGPL = FFmpegConverter.license.contains("LGPL")
            exit(missing.isEmpty && isLGPL ? 0 : 1)
        }
        LoudibleApp.main()
    }
}

struct LoudibleApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = CompositionRoot.makeAppViewModel()

    var body: some Scene {
        Window("Loudible", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 600)
                .task {
                    appDelegate.model = model
                    await model.start()
                }
                // Files may have been added, renamed, or deleted in Finder meanwhile.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.rescan() }
                }
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppViewModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// With jobs running, asks first; on confirmation cancels them and quits once their partial
    /// files are removed. There is no resume, since download URLs expire.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasActiveJobs else { return .terminateNow }
        let count = model.export.activeJobCount
        let alert = NSAlert()
        alert.messageText = count == 1 ? "1 job in progress. Quit anyway?" : "\(count) jobs in progress. Quit anyway?"
        alert.informativeText = "Unfinished downloads and exports are discarded. Finished files are kept."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            await model.export.cancel()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A `swift run` executable starts as a background process; make it a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Builds the production object graph.
@MainActor
enum CompositionRoot {
    static func makeAppViewModel() -> AppViewModel {
        let clock = SystemClock()
        let api = AudibleHTTPAPI(transport: URLSessionTransport(), random: SystemRandom(), clock: clock)
        let auth = AuthenticationCoordinator(api: api, store: KeychainCredentialStore(), clock: clock)
        // Earlier versions downloaded into Caches and deleted the file after exporting.
        try? FileManager.default.removeItem(at: legacyCachesDirectory())
        // Earlier versions let the user choose an export folder; exports now go to the downloads folder.
        UserDefaults.standard.removeObject(forKey: "ExportDestinationPath")
        let downloads = LocalDownloads(folder: downloadsFolder, manifestFolder: manifestsFolder())
        let queue = ExportQueue(
            auth: auth,
            api: api,
            downloader: URLSessionFileDownloader(configuration: .default),
            converter: FFmpegConverter(),
            downloads: downloads
        )
        return AppViewModel(
            session: SessionViewModel(auth: auth),
            library: LibraryViewModel(service: LibraryService(api: api, auth: auth)),
            export: ExportViewModel(queue: queue, exportFolder: downloadsFolder),
            downloads: downloads
        )
    }

    /// Where downloaded `.aaxc`/`.aax` files are kept, and the exported `.m4b` next to them. Hard-coded for now; this is the one place
    /// to change when it becomes a setting.
    static let downloadsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Loudible", isDirectory: true)

    private static var bundleFolderName: String { Bundle.main.bundleIdentifier ?? "Loudible" }

    /// Download manifests hold key material, so they stay out of Documents (synced, shared).
    static func manifestsFolder() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleFolderName, isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The temporary download folder of earlier versions; no longer used.
    static func legacyCachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleFolderName, isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }
}
