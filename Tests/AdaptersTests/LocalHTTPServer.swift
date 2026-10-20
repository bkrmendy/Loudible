import Foundation
import Network

/// Loopback server for native recovery tests: stall, serve a range, or expire the original URL.
final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let body: Data
    private var expired = false
    private var stalls = true
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private var connections: [NWConnection] = []
    private var acceptedCount = 0
    private var receivedHeaders: [[String: String]] = []

    var requestCount: Int { queue.sync { acceptedCount } }
    /// The headers of each request, names lowercased.
    var requests: [[String: String]] { queue.sync { receivedHeaders } }

    /// Releases stalled transfers on future connections, or makes the original URL expire.
    func finishTransfers(expired: Bool = false) {
        queue.sync {
            self.stalls = false
            self.expired = expired
        }
    }

    init(body: Data) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.body = body
    }

    /// Starts listening and returns a URL served by this server.
    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port!.rawValue) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)/content.aaxc")!
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        acceptedCount += 1
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return }
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                var headers: [String: String] = [:]
                guard let request = String(bytes: buffer[..<end.lowerBound], encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                for line in request.components(separatedBy: "\r\n").dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                }
                self.receivedHeaders.append(headers)
                self.respond(on: connection, headers: headers)
            } else if !isComplete {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, headers: [String: String]) {
        let offset = headers["range"].flatMap { Int($0.dropFirst("bytes=".count).dropLast()) } ?? 0
        let start = min(max(0, offset), body.count)
        let status = expired ? 403 : (start > 0 ? 206 : 200)
        let remaining = expired ? Data("expired URL".utf8) : Data(body.dropFirst(start))
        var lines = [
            "HTTP/1.1 \(status) Test", "Content-Length: \(remaining.count)",
            "Content-Type: application/octet-stream", "Connection: close", "Accept-Ranges: bytes",
            "ETag: \"synthetic-v1\"", "Last-Modified: Wed, 14 Oct 2026 10:00:00 GMT"
        ]
        if status == 206 { lines.append("Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)") }
        let head = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if stalls && !expired {
            // Enough bytes for URLSession to create native resume data, then wait for cancellation.
            connection.send(content: head + remaining.prefix(100_000), completion: .contentProcessed { _ in })
        } else {
            connection.send(content: head + remaining, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
