import Foundation

/// A cookie the sign-in browser must carry before loading the login URL.
public struct LoginCookie: Sendable, Hashable {
    public let name: String
    public let value: String
    public let domain: String

    public init(name: String, value: String, domain: String) {
        self.name = name
        self.value = value
        self.domain = domain
    }
}

/// An in-progress sign-in. The PKCE verifier and device identity travel together so the
/// registration request always matches the login that produced the authorization code.
public struct PendingLogin: Sendable, Equatable {
    public let id: UUID
    public let marketplace: Marketplace
    public let device: DeviceIdentity
    public let codeVerifier: String
    public let loginURL: URL
    public let cookies: [LoginCookie]
    /// User agent the sign-in browser should present, so Amazon serves the mobile app flow.
    public let userAgent: String?
    public let createdAt: Date

    public init(
        id: UUID,
        marketplace: Marketplace,
        device: DeviceIdentity,
        codeVerifier: String,
        loginURL: URL,
        cookies: [LoginCookie],
        userAgent: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.marketplace = marketplace
        self.device = device
        self.codeVerifier = codeVerifier
        self.loginURL = loginURL
        self.cookies = cookies
        self.userAgent = userAgent
        self.createdAt = createdAt
    }

    /// Sign-in attempts older than this are rejected as stale.
    public static let lifetime: TimeInterval = 30 * 60

    public func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(createdAt) > Self.lifetime
    }
}

public enum LoginCallbackError: Error, Equatable, Sendable {
    case malformedURL
    case unexpectedHost(String?)
    case unexpectedPath(String)
    case missingAuthorizationCode
    /// No sign-in is waiting: it was cancelled, already completed, or superseded.
    case noPendingLogin
    case expired
}

/// Recognises and validates the Amazon sign-in redirect (`https://www.amazon.<tld>/ap/maplanding`).
public enum LoginCallback {
    public static let path = "/ap/maplanding"
    public static let authorizationCodeParameter = "openid.oa2.authorization_code"

    /// True when the URL is the sign-in redirect for this login, whether or not it carries a code.
    /// The browser uses this to stop navigation and hand the URL over.
    public static func isCallback(_ url: URL, for login: PendingLogin) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.host?.lowercased() == login.marketplace.amazonHost && components.path == path
    }

    /// Extracts the authorization code after checking the scheme, host, and path.
    public static func authorizationCode(from url: URL, for login: PendingLogin) throws(LoginCallbackError) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https"
        else { throw .malformedURL }
        guard components.host?.lowercased() == login.marketplace.amazonHost else {
            throw .unexpectedHost(components.host)
        }
        guard components.path == path else { throw .unexpectedPath(components.path) }
        let codes = (components.queryItems ?? []).filter { $0.name == authorizationCodeParameter }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty else {
            throw .missingAuthorizationCode
        }
        return code
    }
}
