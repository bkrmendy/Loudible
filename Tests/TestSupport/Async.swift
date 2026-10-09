import Foundation

/// Suspends callers until `open()` is called. Lets tests hold a mocked operation mid-flight.
public actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

public struct WaitTimedOut: Error, CustomStringConvertible {
    public let description: String
}

/// Polls `condition` until it holds; throws after `timeout` instead of hanging the test run.
public func waitUntil(
    timeout: Duration = .seconds(5),
    fileID: String = #fileID,
    line: Int = #line,
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await condition()) {
        if ContinuousClock.now >= deadline {
            throw WaitTimedOut(description: "Condition not met within \(timeout) (\(fileID):\(line))")
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}
