// swift-tools-version:6.0
import Foundation
import PackageDescription

/// The FFmpeg built by Scripts/build-ffmpeg.sh, through its version-independent symlink. Found
/// from this file rather than through pkg-config, so Xcode finds it without any environment.
let ffmpeg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/ffmpeg").path

let package = Package(
    name: "Loudible",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Loudible", targets: ["Loudible"]),
        // Consumed by the app target of App/Loudible.xcodeproj.
        .library(name: "LoudibleApp", targets: ["LoudibleApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.12.0"),
    ],
    targets: [
        // Business rules only: Foundation, no UI frameworks, no network/crypto/Keychain code.
        .target(name: "LoudibleScheduling"),
        .target(name: "LoudibleCore", dependencies: ["LoudibleScheduling"]),
        // Audible HTTP API, Keychain, and file downloads.
        .target(
            name: "LoudibleAdapters",
            dependencies: [
                "LoudibleCore",
                .product(name: "Alamofire", package: "Alamofire"),
            ]
        ),
        // Testable view models. Foundation + Observation only.
        .target(
            name: "LoudiblePresentation",
            dependencies: ["LoudibleCore"]
        ),
        // In-process decryption and remuxing with FFmpeg, built by Scripts/build-ffmpeg.sh into
        // Vendor/ffmpeg. Unsafe flags are fine: the package is only ever used locally.
        .systemLibrary(name: "CFFmpegHeaders"),
        .target(
            name: "FFmpegBridge",
            dependencies: ["CFFmpegHeaders"],
            cSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror", "-I\(ffmpeg)/include"])],
            linkerSettings: [
                .unsafeFlags(["-L\(ffmpeg)/lib"]),
                .linkedLibrary("avformat"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"),
            ]
        ),
        .target(
            name: "LoudibleFFmpeg",
            dependencies: [
                "LoudibleCore",
                "FFmpegBridge",
            ]
        ),
        // Views, the composition root, and the launcher. A library so that the `swift run` shell
        // below, the Xcode project's app target, and the snapshot tests can all use it.
        .target(
            name: "LoudibleApp",
            dependencies: [
                "LoudibleCore",
                "LoudibleAdapters",
                "LoudiblePresentation",
                "LoudibleFFmpeg",
            ]
        ),
        // `swift run Loudible`. The Xcode project has its own shell around the same launcher.
        .executableTarget(
            name: "Loudible",
            dependencies: ["LoudibleApp"],
            // SwiftPM's default build system (swiftbuild) stamps the executable with the
            // deployment target as its SDK version (LC_BUILD_VERSION sdk 14.0). macOS then runs
            // the app in compatibility mode with the pre-macOS 26 design: an opaque title bar and
            // a flat sidebar instead of Liquid Glass. Record SDK 26 so the app gets the current
            // system design. Xcode builds against the real SDK and does not need this.
            linkerSettings: [.unsafeFlags([
                "-Xlinker",
                "-platform_version",
                "-Xlinker",
                "macos",
                "-Xlinker",
                "14.0",
                "-Xlinker",
                "26.0"
            ])]),

        .target(
            name: "TestSupport",
            dependencies: ["LoudibleCore", "LoudiblePresentation", "LoudibleApp"],
            path: "Tests/TestSupport"
        ),
        .testTarget(name: "SchedulingTests", dependencies: ["LoudibleScheduling"]),
        .testTarget(
            name: "CoreTests",
            dependencies: ["LoudibleCore", "TestSupport"]
        ),
        .testTarget(
            name: "AdaptersTests",
            dependencies: ["LoudibleAdapters", "LoudibleCore", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PresentationTests",
            dependencies: ["LoudiblePresentation", "LoudibleCore", "TestSupport"]
        ),
    ]
)
