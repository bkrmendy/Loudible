import LoudibleApp

/// The Xcode app target's entry point. Everything else lives in the Swift package at `..`.
@main
enum LoudibleMain {
    @MainActor
    static func main() {
        Launcher.main()
    }
}
