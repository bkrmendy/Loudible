import AudibleExporterApp

/// The Xcode app target's entry point. Everything else lives in the Swift package at `..`.
@main
enum AudibleExporterMain {
    @MainActor
    static func main() {
        Launcher.main()
    }
}
