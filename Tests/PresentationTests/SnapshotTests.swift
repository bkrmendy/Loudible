import Foundation
import Testing
import TestSupport

/// Renders every preview state into `SNAPSHOT_PATH/<state>.png`:
///
///     SNAPSHOT_PATH=/abs/dir Scripts/test.sh --filter Snapshot
///
/// `SNAPSHOT_STATES=tileSelected,windowLibrary` renders only those states.
@Suite struct SnapshotTests {
    /// Entry point for Scripts/render-previews.sh; kept in one test target to render only once.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUDIBLE_PREVIEWS_MODE"] != nil))
    func previewGalleries() async throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["LOUDIBLE_PREVIEWS_MODE"] == "list" {
            Snapshot.list()
            return
        }
        let file = environment["LOUDIBLE_PREVIEWS_FILE"].flatMap { $0.isEmpty ? nil : $0 }
        let states = environment["LOUDIBLE_PREVIEWS_STATES"].flatMap { value -> Set<String>? in
            guard !value.isEmpty else { return nil }
            return Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        let root = environment["LOUDIBLE_PREVIEWS_OUTPUT"].flatMap { value -> URL? in
            value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
        }
        try await Snapshot.galleries(to: root, file: file, states: states)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SNAPSHOT_PATH"] != nil))
    func snapshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        let states = environment["SNAPSHOT_STATES"].map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        let folder = URL(fileURLWithPath: environment["SNAPSHOT_PATH"]!, isDirectory: true)
        let written = try await Snapshot.run(to: folder, states: states)
        #expect(!written.isEmpty)
    }
}
