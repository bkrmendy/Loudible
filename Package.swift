// swift-tools-version:6.0
import Foundation
import PackageDescription

/// The FFmpeg built by Scripts/build-ffmpeg.sh, through its version-independent symlink. Found
/// from this file rather than through pkg-config, so Xcode finds it without any environment.
let ffmpeg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/ffmpeg").path

let package = Package(
    name: "AudibleExporter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AudibleExporter", targets: ["AudibleExporter"]),
        // Consumed by the app target of App/AudibleExporter.xcodeproj.
        .library(name: "AudibleExporterApp", targets: ["AudibleExporterApp"]),
    ],
    targets: [
        // Business rules only: Foundation, no UI frameworks, no network/crypto/Keychain code.
        .target(name: "AudibleExporterCore"),
        // Audible HTTP API, Keychain, and file downloads.
        .target(
            name: "AudibleExporterAdapters",
            dependencies: ["AudibleExporterCore"]
        ),
        // Testable view models. Foundation + Observation only.
        .target(
            name: "AudibleExporterPresentation",
            dependencies: ["AudibleExporterCore"]
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
            name: "AudibleExporterFFmpeg",
            dependencies: [
                "AudibleExporterCore",
                "FFmpegBridge",
            ]
        ),
        // Views, the composition root, and the launcher. A library so that the `swift run` shell
        // below, the Xcode project's app target, and the snapshot tests can all use it.
        .target(
            name: "AudibleExporterApp",
            dependencies: [
                "AudibleExporterCore",
                "AudibleExporterAdapters",
                "AudibleExporterPresentation",
                "AudibleExporterFFmpeg",
            ]
        ),
        // `swift run AudibleExporter`. The Xcode project has its own shell around the same launcher.
        .executableTarget(
            name: "AudibleExporter",
            dependencies: ["AudibleExporterApp"],
            // SwiftPM's default build system (swiftbuild) stamps the executable with the
            // deployment target as its SDK version (LC_BUILD_VERSION sdk 14.0). macOS then runs
            // the app in compatibility mode with the pre-macOS 26 design: an opaque title bar and
            // a flat sidebar instead of Liquid Glass. Record SDK 26 so the app gets the current
            // system design. Xcode builds against the real SDK and does not need this.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"])]
        ),

        .target(
            name: "TestSupport",
            dependencies: ["AudibleExporterCore", "AudibleExporterPresentation", "AudibleExporterApp"],
            path: "Tests/TestSupport"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["AudibleExporterCore", "TestSupport"]
        ),
        .testTarget(
            name: "AdaptersTests",
            dependencies: ["AudibleExporterAdapters", "AudibleExporterCore", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PresentationTests",
            dependencies: ["AudibleExporterPresentation", "AudibleExporterCore", "TestSupport"]
        ),
    ]
)
