import Foundation
import Security
import AudibleExporterCore

/// Signs Audible API requests with the device's RSA key (ADP signing):
/// `base64(RSA-PKCS1v1.5-SHA256("<METHOD>\n<path?query>\n<date>\n<body>\n<adp token>"))`.
public struct RequestSigner {
    public enum SigningError: Error, Equatable {
        case invalidPEM
        case unsupportedKeyFormat
        case keyCreationFailed(String)
        case signingFailed(String)
    }

    private let adpToken: String
    private let key: SecKey

    public init(adpToken: String, privateKeyPEM: String) throws(SigningError) {
        self.adpToken = adpToken
        self.key = try Self.makeKey(pem: privateKeyPEM)
    }

    /// Adds `x-adp-token`, `x-adp-alg`, and `x-adp-signature` headers.
    public func sign(_ request: inout URLRequest, date: Date) throws(SigningError) {
        let timestamp = Self.timestamp(date)
        let signature = try signature(
            method: request.httpMethod ?? "GET",
            pathAndQuery: Self.pathAndQuery(of: request.url!),
            timestamp: timestamp,
            body: request.httpBody ?? Data()
        )
        request.setValue(adpToken, forHTTPHeaderField: "x-adp-token")
        request.setValue("SHA256withRSA:1.0", forHTTPHeaderField: "x-adp-alg")
        request.setValue("\(signature):\(timestamp)", forHTTPHeaderField: "x-adp-signature")
    }

    func signature(method: String, pathAndQuery: String, timestamp: String, body: Data) throws(SigningError) -> String {
        var message = Data("\(method)\n\(pathAndQuery)\n\(timestamp)\n".utf8)
        message.append(body)
        message.append(Data("\n\(adpToken)".utf8))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error
        ) as Data? else {
            throw .signingFailed(error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown")
        }
        return signature.base64EncodedString()
    }

    static func pathAndQuery(of url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? url.path
        if let query = components?.percentEncodedQuery { return "\(path)?\(query)" }
        return path
    }

    /// UTC ISO-8601 timestamp with microseconds, e.g. `2027-01-15T08:00:00.000000Z`.
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let seconds = date.timeIntervalSince1970
        let microseconds = Int(((seconds - seconds.rounded(.down)) * 1_000_000).rounded(.down))
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%06dZ",
            parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!, microseconds
        )
    }

    // MARK: Key loading

    static func makeKey(pem: String) throws(SigningError) -> SecKey {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let header = lines.first, header.hasPrefix("-----BEGIN ") else { throw .invalidPEM }
        let body = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body), !der.isEmpty else { throw .invalidPEM }

        let pkcs1: Data
        switch header {
        case "-----BEGIN RSA PRIVATE KEY-----":
            pkcs1 = der
        case "-----BEGIN PRIVATE KEY-----":
            guard let unwrapped = DER.pkcs1FromPKCS8(der) else { throw .unsupportedKeyFormat }
            pkcs1 = unwrapped
        default:
            throw .unsupportedKeyFormat
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw .keyCreationFailed(error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown")
        }
        return key
    }
}

/// Minimal DER reader for unwrapping a PKCS#8 RSA key.
enum DER {
    /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING, ... }
    static func pkcs1FromPKCS8(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let outer = element(in: bytes, at: 0), outer.tag == 0x30 else { return nil }
        var offset = outer.contentStart
        guard let version = element(in: bytes, at: offset), version.tag == 0x02 else { return nil }
        offset = version.end
        guard let algorithm = element(in: bytes, at: offset), algorithm.tag == 0x30 else { return nil }
        offset = algorithm.end
        guard let key = element(in: bytes, at: offset), key.tag == 0x04 else { return nil }
        return Data(bytes[key.contentStart..<key.end])
    }

    private static func element(in bytes: [UInt8], at offset: Int) -> (tag: UInt8, contentStart: Int, end: Int)? {
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        var length = Int(bytes[offset + 1])
        var contentStart = offset + 2
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count > 0, count <= 4, contentStart + count <= bytes.count else { return nil }
            length = bytes[contentStart..<contentStart + count].reduce(0) { $0 << 8 | Int($1) }
            contentStart += count
        }
        let end = contentStart + length
        guard end <= bytes.count else { return nil }
        return (tag, contentStart, end)
    }
}
