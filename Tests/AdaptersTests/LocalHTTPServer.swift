import Foundation
import Network

/// A loopback-only HTTP/1.1 server for download tests. Each connection gets one canned reply.
final class LocalHTTPServer: @unchecked Sendable {
    /// A file served with `Range` support.
    struct File: Sendable {
        var body: Data
        var etag: String?
        var lastModified: String?
        /// Answers ranged requests with 200 and the whole body when false.
        var honorsRange = true
        /// Sends 206 for a range even when `If-Range` doesn't match, as a broken server would.
        var ignoresIfRange = false
        /// Answers every ranged request with this status instead (e.g. 416).
        var rangeStatus: Int?
        /// Sends only this many body bytes, then closes the connection.
        var dropAfter: Int?
        /// Sends this many body bytes, waits a moment, then the rest; so they arrive in two parts.
        var pauseAfter: Int?
    }

    enum Reply: Sendable {
        case file(File)
        /// 200 with the whole body.
        case body(Data)
        /// Announces `declaredLength` bytes but sends `body` and closes the connection.
        case truncated(body: Data, declaredLength: Int)
        case status(Int)
        /// Sends the headers and `body` (a prefix of `declaredLength`), then waits forever.
        case stall(body: Data, declaredLength: Int)
    }

    private let listener: NWListener
    private let reply: Reply
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private var connections: [NWConnection] = []
    private var acceptedCount = 0
    private var receivedHeaders: [[String: String]] = []

    var requestCount: Int { queue.sync { acceptedCount } }
    /// The headers of each request, names lowercased.
    var requests: [[String: String]] { queue.sync { receivedHeaders } }

    init(reply: Reply) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.reply = reply
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
        func head(_ status: Int, length: Int, extra: [String] = []) -> Data {
            let lines = [
                "HTTP/1.1 \(status) Test",
                "Content-Length: \(length)",
                "Content-Type: application/octet-stream",
                "Connection: close"
            ] + extra
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        }
        @Sendable func sendAndClose(_ data: Data) {
            connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
        /// Closing right after the bytes would make URLSession drop them unseen; a real
        /// connection breaking mid-transfer has delivered what came before.
        func sendThenDrop(_ data: Data) {
            connection.send(content: data, completion: .contentProcessed { [queue] _ in
                queue.asyncAfter(deadline: .now() + 0.1) { connection.cancel() }
            })
        }
        switch reply {
        case .file(let file):
            let validators = [file.etag.map { "ETag: \($0)" }, file.lastModified.map { "Last-Modified: \($0)" }]
                .compactMap { $0 }
            var start = 0
            if let range = headers["range"], range.hasPrefix("bytes="), range.hasSuffix("-"),
               let offset = Int(range.dropFirst("bytes=".count).dropLast()) {
                if let status = file.rangeStatus {
                    return sendAndClose(head(status, length: 0))
                }
                let ifRange = headers["if-range"]
                let sameFile = ifRange == nil || ifRange == file.etag || ifRange == file.lastModified
                if file.honorsRange && (sameFile || file.ignoresIfRange) && offset < file.body.count { start = offset }
            }
            let body = Data(file.body.dropFirst(start))
            let status = start > 0 ? 206 : 200
            let range = start > 0 ? ["Content-Range: bytes \(start)-\(file.body.count - 1)/\(file.body.count)"] : []
            let head = head(status, length: body.count, extra: validators + range)
            if let dropAfter = file.dropAfter {
                sendThenDrop(head + body.prefix(dropAfter))
            } else if let pauseAfter = file.pauseAfter {
                connection.send(content: head + body.prefix(pauseAfter), completion: .contentProcessed { [queue] _ in
                    queue.asyncAfter(deadline: .now() + 0.1) { sendAndClose(Data(body.dropFirst(pauseAfter))) }
                })
            } else {
                sendAndClose(head + body)
            }
        case .body(let body):
            connection.send(
                content: head(200, length: body.count) + body,
                isComplete: true,
                completion: .contentProcessed { _ in
                connection.cancel()
            })
        case .truncated(let body, let declaredLength):
            sendThenDrop(head(200, length: declaredLength) + body)
        case .status(let status):
            let body = Data("error \(status)".utf8)
            connection.send(
                content: head(status, length: body.count) + body,
                isComplete: true,
                completion: .contentProcessed { _ in
                connection.cancel()
            })
        case .stall(let body, let declaredLength):
            connection.send(content: head(200, length: declaredLength) + body, completion: .contentProcessed { _ in })
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
