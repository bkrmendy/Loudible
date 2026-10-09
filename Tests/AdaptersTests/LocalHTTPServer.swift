import Foundation
import Network

/// A loopback-only HTTP/1.1 server for download tests. Each connection gets one canned reply.
final class LocalHTTPServer: @unchecked Sendable {
    enum Reply: Sendable {
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

    var requestCount: Int { queue.sync { acceptedCount } }

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
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(on: connection)
            } else if !isComplete {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection) {
        func head(_ status: Int, length: Int) -> Data {
            Data("HTTP/1.1 \(status) Test\r\nContent-Length: \(length)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n".utf8)
        }
        switch reply {
        case .body(let body):
            connection.send(content: head(200, length: body.count) + body, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        case .truncated(let body, let declaredLength):
            connection.send(content: head(200, length: declaredLength) + body, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        case .status(let status):
            let body = Data("error \(status)".utf8)
            connection.send(content: head(status, length: body.count) + body, isComplete: true, completion: .contentProcessed { _ in
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
