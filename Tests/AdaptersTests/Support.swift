import Foundation
import Security
@testable import LoudibleAdapters
import LoudibleCore
import TestSupport

/// Canned HTTP responses. Requests that no handler claims fail the test via `Unhandled`.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Unhandled: Error { let url: URL? }

    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data, [String: String])

    let handler: Locked<Handler>
    let requests = Locked<[URLRequest]>([])

    init(_ handler: @escaping Handler = { request in throw Unhandled(url: request.url) }) {
        self.handler = Locked(handler)
    }

    /// Replies to every request with the same status and body.
    convenience init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.init { _ in (status, body, headers) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let (status, data, headers) = try await handler.current(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (data, response)
    }

    var lastRequest: URLRequest? { requests.current.last }
}

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    static func json(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data(name)) as! [String: Any]
    }

    /// A session whose device key is the synthetic test key, so requests can really be signed.
    static func signingSession(marketplace: Marketplace = .us) throws -> AudibleSession {
        var session = Fixtures.session(marketplace: marketplace)
        session.devicePrivateKey = try string("synthetic-device-key.pem")
        session.adpToken = "{enc:synthetic-adp-token}"
        return session
    }
}

/// In-memory Keychain keyed by service and account, with injectable failures.
final class FakeKeychain: KeychainServices, @unchecked Sendable {
    let items = Locked<[String: [String: Any]]>([:])
    let forcedStatus = Locked<[String: OSStatus]>([:])
    let lastQuery = Locked<[String: Any]>([:])

    private func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] ?? "")|\(query[kSecAttrAccount as String] ?? "")"
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lastQuery.withLock { $0 = attributes }
        if let status = forcedStatus.current["add"] { return status }
        return items.withLock { items in
            if items[key(attributes)] != nil { return errSecDuplicateItem }
            items[key(attributes)] = attributes
            return errSecSuccess
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        lastQuery.withLock { $0 = query }
        if let status = forcedStatus.current["copy"] { return (status, nil) }
        guard let item = items.current[key(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, item[kSecValueData as String] as AnyObject?)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lastQuery.withLock { $0 = query }
        if let status = forcedStatus.current["update"] { return status }
        return items.withLock { items in
            guard var item = items[key(query)] else { return errSecItemNotFound }
            item.merge(attributes) { $1 }
            items[key(query)] = item
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lastQuery.withLock { $0 = query }
        if let status = forcedStatus.current["delete"] { return status }
        return items.withLock { $0.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess }
    }
}

extension URLRequest {
    var jsonBody: [String: Any]? {
        httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    var formBody: [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: httpBody ?? Data(), as: UTF8.self)
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    var queryItems: [String: String] {
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }
}
