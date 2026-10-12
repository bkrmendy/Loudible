import Foundation

public struct Chapter: Sendable, Hashable, Codable {
    public var title: String
    public var startMilliseconds: Int
    public var lengthMilliseconds: Int

    public init(title: String, startMilliseconds: Int, lengthMilliseconds: Int) {
        self.title = title
        self.startMilliseconds = startMilliseconds
        self.lengthMilliseconds = lengthMilliseconds
    }

    public var endMilliseconds: Int { startMilliseconds + lengthMilliseconds }
}

/// A granted download license with everything needed to fetch and decrypt one title.
public struct ContentLicense: Sendable, Equatable {
    /// Codable so a download's manifest can keep it for offline export (`Data` encodes as base64).
    public enum Decryption: Sendable, Equatable, Codable {
        /// AAXC: per-title AES key and IV from the decrypted voucher.
        case aaxc(key: Data, iv: Data)
        /// Legacy AAX: 4 activation bytes.
        case aax(activationBytes: Data)

        /// Extension of the encrypted file this scheme decrypts.
        public var fileExtension: String {
            switch self {
            case .aaxc: "aaxc"
            case .aax: "aax"
            }
        }
    }

    public let asin: String
    public let decryption: Decryption
    public let downloadURL: URL
    public let chapters: [Chapter]
    public let runtimeMilliseconds: Int?
    public let codec: String?
    public let contentFormat: String?

    public init(
        asin: String,
        decryption: Decryption,
        downloadURL: URL,
        chapters: [Chapter],
        runtimeMilliseconds: Int? = nil,
        codec: String? = nil,
        contentFormat: String? = nil
    ) {
        self.asin = asin
        self.decryption = decryption
        self.downloadURL = downloadURL
        self.chapters = chapters
        self.runtimeMilliseconds = runtimeMilliseconds
        self.codec = codec
        self.contentFormat = contentFormat
    }

    /// Chooses the decryption scheme from the license DRM type and voucher key material,
    /// following Libation's rules: ADRM with a 4-byte key and no IV is AAX; ADRM with a
    /// 16-byte key and 16-byte IV is AAXC. Anything else is unsupported.
    public static func decryption(
        asin: String,
        drmType: String?,
        key: Data?,
        iv: Data?
    ) throws(ExporterError) -> Decryption {
        guard drmType?.lowercased() == "adrm" else {
            throw .unsupportedDRM(asin: asin, drmType: drmType ?? "none")
        }
        guard let key, !key.isEmpty else { throw .missingDecryptionKey(asin: asin) }
        switch (key.count, iv?.count) {
        case (4, nil):
            return .aax(activationBytes: key)
        case (16, 16?):
            return .aaxc(key: key, iv: iv!)
        default:
            throw .unsupportedDRM(asin: asin, drmType: "Adrm (key \(key.count) bytes, iv \(iv?.count ?? 0) bytes)")
        }
    }
}
