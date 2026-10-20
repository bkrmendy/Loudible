import CryptoKit
import Foundation
import LoudibleCore

/// Builds the Audible for iPhone sign-in: device serial, PKCE pair, login URL, and the
/// cookies Amazon expects the app's web view to carry.
public struct AudibleLoginFactory: Sendable {
    /// Constants identifying the emulated Audible iOS app.
    public enum App {
        public static let version = "3.56.2"
        public static let softwareVersion = "35602678"
        public static let osVersion = "15.0.0"
        public static let bundleID = "com.audible.iphone"
        public static let appID = "MAPiOSLib/6.0/ToHideRetailLink"
        public static let webUserAgent =
            """
            Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) \
            Mobile/15E148
            """
        public static let apiUserAgent = "AmazonWebView/Audible/\(version)/iOS/\(osVersion)/iPhone"
    }

    private let random: any RandomSource
    private let clock: any WallClock

    public init(random: any RandomSource, clock: any WallClock) {
        self.random = random
        self.clock = clock
    }

    public func makeLogin(for marketplace: Marketplace) -> PendingLogin {
        let serial = random.uuid().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        let device = DeviceIdentity(serial: serial)
        let verifier = PKCE.codeVerifier(from: random.bytes(count: 32))
        return PendingLogin(
            id: random.uuid(),
            marketplace: marketplace,
            device: device,
            codeVerifier: verifier,
            loginURL: Self.loginURL(
                marketplace: marketplace,
                device: device,
                codeChallenge: PKCE.codeChallenge(for: verifier)),
            cookies: initialCookies(marketplace: marketplace),
            userAgent: App.webUserAgent,
            createdAt: clock.now())
    }

    static func loginURL(marketplace: Marketplace, device: DeviceIdentity, codeChallenge: String) -> URL {
        let identifierSelect = "http://specs.openid.net/auth/2.0/identifier_select"
        var components = URLComponents()
        components.scheme = "https"
        components.host = marketplace.amazonHost
        components.path = "/ap/signin"
        components.queryItems = [
            ("openid.oa2.response_type", "code"),
            ("openid.oa2.code_challenge_method", "S256"),
            ("openid.oa2.code_challenge", codeChallenge),
            ("openid.return_to", "https://\(marketplace.amazonHost)\(LoginCallback.path)"),
            ("openid.assoc_handle", "amzn_audible_ios_\(marketplace.id)"),
            ("openid.identity", identifierSelect),
            ("pageId", "amzn_audible_ios"),
            ("accountStatusPolicy", "P1"),
            ("openid.claimed_id", identifierSelect),
            ("openid.mode", "checkid_setup"),
            ("openid.ns.oa2", "http://www.amazon.com/ap/ext/oauth/2"),
            ("openid.oa2.client_id", "device:\(device.clientID)"),
            ("openid.ns.pape", "http://specs.openid.net/extensions/pape/1.0"),
            ("marketPlaceId", marketplace.marketplaceID),
            ("openid.oa2.scope", "device_auth_access"),
            ("forceMobileLayout", "true"),
            ("openid.ns", "http://specs.openid.net/auth/2.0"),
            ("openid.pape.max_auth_age", "0"),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents leaves "+" alone in query values; encode it so it is not read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    func initialCookies(marketplace: Marketplace) -> [LoginCookie] {
        let domain = ".amazon.\(marketplace.domain)"
        let frc = random.bytes(count: 313).base64EncodedString().trimmingCharacters(in: ["="])
        let metadata = """
        {"device_user_dictionary":[],"device_registration_data":{"software_version":"\(App.softwareVersion)"},\
        "app_identifier":{"app_version":"\(App.version)","bundle_id":"\(App.bundleID)"}}
        """
        let mapMD = Data(metadata.utf8).base64EncodedString().trimmingCharacters(in: ["="])
        return [
            LoginCookie(name: "frc", value: frc, domain: domain),
            LoginCookie(name: "map-md", value: mapMD, domain: domain),
            LoginCookie(name: "amzn-app-id", value: App.appID, domain: domain),
        ]
    }
}

/// RFC 7636 proof key helpers.
public enum PKCE {
    public static func codeVerifier(from bytes: Data) -> String {
        bytes.base64URLEncodedString()
    }

    public static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

extension Data {
    /// Base64url without padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: ["="])
    }
}
