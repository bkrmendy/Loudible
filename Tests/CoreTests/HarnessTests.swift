import Foundation
import Testing
import TestSupport

/// Verifies the guarantees `Scripts/test.sh` provides. Skipped when tests run outside it.
@Suite(.enabled(if: TestHarness.isSandboxed, "Run via Scripts/test.sh to enable harness checks"))
struct HarnessTests {
    @Test func externalNetworkConnectionsAreRejected() {
        // 192.0.2.1 is TEST-NET-1; the sandbox must refuse the connect before any packet leaves.
        let result = TestHarness.connect(toIPv4: "192.0.2.1", port: 443)
        #expect(result == EPERM)
    }

    @Test func externalURLSessionRequestsFail() async {
        let session = URLSession(configuration: .ephemeral)
        await #expect(throws: (any Error).self) {
            _ = try await session.data(from: URL(string: "https://192.0.2.1/")!)
        }
    }

    @Test func temporaryDirectoriesAreIsolated() throws {
        let first = try TemporaryDirectory(), second = try TemporaryDirectory()
        defer { first.cleanUp(); second.cleanUp() }
        #expect(first.url != second.url)
        #expect(first.contents().isEmpty)
    }
}
