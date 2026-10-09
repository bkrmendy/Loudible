import Foundation

public enum TestHarness {
    /// Set by `Scripts/test.sh`, which runs the tests in a sandbox that denies non-loopback network access.
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["AUDIBLE_EXPORTER_TEST_SANDBOX"] == "1"
    }

    /// Attempts a blocking TCP connect and returns 0 on success or the resulting errno.
    public static func connect(toIPv4 address: String, port: UInt16) -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var socketAddress = sockaddr_in()
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &socketAddress.sin_addr)
        let result = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0 ? 0 : errno
    }
}
