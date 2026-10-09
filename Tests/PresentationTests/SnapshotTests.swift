import Foundation
import Testing
import TestSupport

/// Renders every preview state into `SNAPSHOT_PATH/<state>.png`:
///
///     SNAPSHOT_PATH=/abs/dir Scripts/test.sh --filter Snapshot
///
/// `SNAPSHOT_STATES=tileSelected,windowLibrary` renders only those states.
@Suite struct SnapshotTests {
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
