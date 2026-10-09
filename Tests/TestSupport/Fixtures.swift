import Foundation
import AudibleExporterCore

/// Deterministic, synthetic test data. Nothing here belongs to a real account.
public enum Fixtures {
    public static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    public static let device = DeviceIdentity(serial: "0123456789ABCDEF0123456789ABCDEF")

    public static func session(
        marketplace: Marketplace = .us,
        accessToken: String = "Atna|synthetic-access",
        expiresAt: Date = referenceDate.addingTimeInterval(3600),
        refreshToken: String = "Atnr|synthetic-refresh"
    ) -> AudibleSession {
        AudibleSession(
            marketplace: marketplace,
            device: device,
            customerID: "amzn1.account.SYNTHETIC",
            customerName: "Test User",
            accessToken: accessToken,
            accessTokenExpiresAt: expiresAt,
            refreshToken: refreshToken,
            adpToken: "{enc:synthetic}{key:synthetic}",
            devicePrivateKey: "-----BEGIN RSA PRIVATE KEY-----\nsynthetic\n-----END RSA PRIVATE KEY-----\n"
        )
    }

    public static func pendingLogin(
        marketplace: Marketplace = .us,
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
        createdAt: Date = referenceDate
    ) -> PendingLogin {
        PendingLogin(
            id: id,
            marketplace: marketplace,
            device: device,
            codeVerifier: "synthetic-verifier",
            loginURL: URL(string: "https://\(marketplace.amazonHost)/ap/signin?synthetic=1")!,
            cookies: [LoginCookie(name: "frc", value: "x", domain: ".amazon.\(marketplace.domain)")],
            createdAt: createdAt
        )
    }

    public static func callbackURL(marketplace: Marketplace = .us, code: String = "synthetic-code") -> URL {
        URL(string: "https://\(marketplace.amazonHost)/ap/maplanding?openid.assoc_handle=amzn_audible_ios_us&openid.oa2.authorization_code=\(code)")!
    }

    public static func book(_ asin: String, title: String? = nil, authors: [String] = ["Author A"]) -> Audiobook {
        Audiobook(asin: asin, title: title ?? "Book \(asin)", authors: authors, narrators: ["Narrator N"])
    }

    public static func entry(
        _ asin: String,
        title: String? = nil,
        deliveryType: String = "SinglePartBook",
        contentType: String = "Product",
        isAYCE: Bool = false,
        relationships: [ProductRelationship] = []
    ) -> LibraryEntry {
        LibraryEntry(
            book: book(asin, title: title),
            contentDeliveryType: deliveryType,
            contentType: contentType,
            isAYCE: isAYCE,
            relationships: relationships
        )
    }

    public static func license(asin: String) -> ContentLicense {
        ContentLicense(
            asin: asin,
            decryption: .aaxc(key: Data(repeating: 0x11, count: 16), iv: Data(repeating: 0x22, count: 16)),
            downloadURL: URL(string: "https://cdn.example.invalid/\(asin).aaxc")!,
            chapters: [Chapter(title: "Chapter 1", startMilliseconds: 0, lengthMilliseconds: 60_000)],
            runtimeMilliseconds: 60_000,
            codec: "mp4a.40.2",
            contentFormat: "AAX_44_128"
        )
    }
}

/// A uniquely named directory under the system temporary directory, removed on `cleanUp()`.
public struct TemporaryDirectory: Sendable {
    public let url: URL

    public init(_ label: String = "test") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudibleExporterTests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }

    public func contents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}
