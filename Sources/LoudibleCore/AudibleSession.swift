import Foundation

/// The registered virtual device. Generated once per sign-in attempt and kept with the
/// pending PKCE verifier, because registration must present the same serial the login used.
public struct DeviceIdentity: Sendable, Hashable, Codable {
    /// Audible for iPhone device type.
    public static let iPhoneDeviceType = "A2CZJZGLK2JJVM"

    public let serial: String
    public let deviceType: String

    public init(serial: String, deviceType: String = DeviceIdentity.iPhoneDeviceType) {
        self.serial = serial
        self.deviceType = deviceType
    }

    /// OAuth client id: hex of `"<serial>#<deviceType>"`.
    public var clientID: String {
        Data("\(serial)#\(deviceType)".utf8).hexString
    }
}

/// A registered, signed-in Audible device and its tokens.
public struct AudibleSession: Sendable, Equatable, Codable {
    public var marketplace: Marketplace
    public var device: DeviceIdentity
    /// Amazon customer id (`customer_info.user_id`). Part of the voucher key derivation.
    public var customerID: String
    public var customerName: String?
    public var accessToken: String
    public var accessTokenExpiresAt: Date
    public var refreshToken: String
    /// MAC/DMS token used to sign Audible API requests.
    public var adpToken: String
    /// PEM-encoded RSA private key issued at registration.
    public var devicePrivateKey: String

    public init(
        marketplace: Marketplace,
        device: DeviceIdentity,
        customerID: String,
        customerName: String?,
        accessToken: String,
        accessTokenExpiresAt: Date,
        refreshToken: String,
        adpToken: String,
        devicePrivateKey: String
    ) {
        self.marketplace = marketplace
        self.device = device
        self.customerID = customerID
        self.customerName = customerName
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.adpToken = adpToken
        self.devicePrivateKey = devicePrivateKey
    }

    /// Default margin before expiry at which the access token is refreshed.
    public static let refreshLeeway: TimeInterval = 300

    public func needsRefresh(at now: Date, leeway: TimeInterval = AudibleSession.refreshLeeway) -> Bool {
        now.addingTimeInterval(leeway) >= accessTokenExpiresAt
    }
}
