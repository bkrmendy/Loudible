import Foundation
import AudibleExporterCore

/// `AudibleAPI` over HTTPS, emulating the Audible for iPhone app.
public struct AudibleHTTPAPI: AudibleAPI {
    let transport: any HTTPTransport
    let clock: any WallClock
    let loginFactory: AudibleLoginFactory

    public init(transport: any HTTPTransport, random: any RandomSource, clock: any WallClock) {
        self.transport = transport
        self.clock = clock
        self.loginFactory = AudibleLoginFactory(random: random, clock: clock)
    }

    public func makeLogin(for marketplace: Marketplace) throws -> PendingLogin {
        loginFactory.makeLogin(for: marketplace)
    }

    // MARK: Registration

    public func register(_ login: PendingLogin, authorizationCode: String) async throws -> AudibleSession {
        let request = try DeviceRegistration.request(for: login, authorizationCode: authorizationCode)
        let (data, response) = try await send(request)
        return try DeviceRegistration.session(from: data, status: response.statusCode, login: login, receivedAt: clock.now())
    }

    // MARK: Token refresh

    public func refresh(_ session: AudibleSession) async throws -> AudibleSession {
        let request = TokenRefresh.request(for: session)
        let (data, response) = try await send(request)
        return try TokenRefresh.session(byApplying: data, status: response.statusCode, to: session, receivedAt: clock.now())
    }

    // MARK: Library and licenses

    // Signing covers method, path, query, date and body but not the host, so the session's
    // device key signs requests to any store.

    public func libraryPage(_ number: Int, pageSize: Int, marketplace: Marketplace, session: AudibleSession) async throws -> LibraryPage {
        let request = try signed(LibraryRequest.request(page: number, pageSize: pageSize, marketplace: marketplace), session: session)
        let (data, response) = try await send(request)
        return try LibraryParser.page(from: data, response: response, marketplace: marketplace)
    }

    public func license(for asin: String, marketplace: Marketplace, session: AudibleSession) async throws -> ContentLicense {
        let unsigned: URLRequest
        do {
            unsigned = try LicenseRequest.request(asin: asin, marketplace: marketplace)
        } catch {
            throw ExporterError.unexpected("Could not encode license request: \(error)")
        }
        let (data, response) = try await send(try signed(unsigned, session: session))
        return try LicenseParser.license(from: data, response: response, asin: asin, session: session)
    }

    // MARK: Transport

    func send(_ request: URLRequest) async throws(ExporterError) -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw ExporterError.from(error)
        }
    }

    /// Signs a request to the Audible API with the session's device key.
    func signed(_ request: URLRequest, session: AudibleSession) throws(ExporterError) -> URLRequest {
        var request = request
        do {
            try RequestSigner(adpToken: session.adpToken, privateKeyPEM: session.devicePrivateKey)
                .sign(&request, date: clock.now())
        } catch {
            // A key we cannot use is as good as no credentials.
            throw .authenticationRequired
        }
        return request
    }
}

// MARK: - Amazon auth endpoints

enum AmazonAuthHeaders {
    static func apply(to request: inout URLRequest, marketplace: Marketplace, contentType: String) {
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("utf-8", forHTTPHeaderField: "Accept-Charset")
        request.setValue(marketplace.amazonAPIHost, forHTTPHeaderField: "x-amzn-identity-auth-domain")
        request.setValue(AudibleLoginFactory.App.apiUserAgent, forHTTPHeaderField: "User-Agent")
    }
}

enum DeviceRegistration {
    static func request(for login: PendingLogin, authorizationCode: String) throws -> URLRequest {
        let body: [String: Any] = [
            "requested_token_type": ["bearer", "mac_dms", "website_cookies", "store_authentication_cookie"],
            "cookies": ["website_cookies": [Any](), "domain": ".amazon.\(login.marketplace.domain)"],
            "registration_data": [
                "domain": "Device",
                "app_version": AudibleLoginFactory.App.version,
                "device_serial": login.device.serial,
                "device_type": login.device.deviceType,
                "device_name": "%FIRST_NAME%%FIRST_NAME_POSSESSIVE_STRING%%DUPE_STRATEGY_1ST%Audible for iPhone",
                "os_version": AudibleLoginFactory.App.osVersion,
                "software_version": AudibleLoginFactory.App.softwareVersion,
                "device_model": "iPhone",
                "app_name": "Audible",
            ],
            "auth_data": [
                "client_id": login.device.clientID,
                "authorization_code": authorizationCode,
                "code_verifier": login.codeVerifier,
                "code_algorithm": "SHA-256",
                "client_domain": "DeviceLegacy",
            ],
            "requested_extensions": ["device_info", "customer_info"],
        ]
        var request = URLRequest(url: URL(string: "https://\(login.marketplace.amazonAPIHost)/auth/register")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        AmazonAuthHeaders.apply(to: &request, marketplace: login.marketplace, contentType: "application/json")
        return request
    }

    static func session(from data: Data, status: Int, login: PendingLogin, receivedAt now: Date) throws(ExporterError) -> AudibleSession {
        let json = JSON(data: data)
        guard (200..<300).contains(status) else {
            let error = json["response"]["error"]
            throw .http(status: status, message: error["message"].string ?? error["code"].string)
        }
        let success = json["response"]["success"]
        let bearer = success["tokens"]["bearer"]
        let macDMS = success["tokens"]["mac_dms"]
        let customer = success["extensions"]["customer_info"]

        guard let accessToken = bearer["access_token"].string,
              let refreshToken = bearer["refresh_token"].string,
              let expiresIn = bearer["expires_in"].int,
              let adpToken = macDMS["adp_token"].string,
              let privateKey = macDMS["device_private_key"].string,
              let customerID = customer["user_id"].string
        else {
            throw .malformedResponse("Device registration response is missing tokens.")
        }
        let deviceInfo = success["extensions"]["device_info"]
        let device = DeviceIdentity(
            serial: deviceInfo["device_serial_number"].string ?? login.device.serial,
            deviceType: deviceInfo["device_type"].string ?? login.device.deviceType
        )
        guard device == login.device else {
            throw .malformedResponse("Audible registered a different device than the one that signed in.")
        }
        return AudibleSession(
            marketplace: login.marketplace,
            device: device,
            customerID: customerID,
            customerName: customer["given_name"].string ?? customer["name"].string,
            accessToken: accessToken,
            accessTokenExpiresAt: now.addingTimeInterval(TimeInterval(expiresIn)),
            refreshToken: refreshToken,
            adpToken: adpToken,
            devicePrivateKey: privateKey
        )
    }
}

enum TokenRefresh {
    static func request(for session: AudibleSession) -> URLRequest {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "app_name", value: "Audible"),
            URLQueryItem(name: "app_version", value: AudibleLoginFactory.App.version),
            URLQueryItem(name: "source_token", value: session.refreshToken),
            URLQueryItem(name: "requested_token_type", value: "access_token"),
            URLQueryItem(name: "source_token_type", value: "refresh_token"),
        ]
        var request = URLRequest(url: URL(string: "https://\(session.marketplace.amazonAPIHost)/auth/token")!)
        request.httpMethod = "POST"
        request.httpBody = Data(FormEncoding.encode(components.queryItems!).utf8)
        AmazonAuthHeaders.apply(to: &request, marketplace: session.marketplace, contentType: "application/x-www-form-urlencoded")
        return request
    }

    static func session(byApplying data: Data, status: Int, to session: AudibleSession, receivedAt now: Date) throws(ExporterError) -> AudibleSession {
        let json = JSON(data: data)
        guard (200..<300).contains(status) else {
            // Amazon reports a revoked or expired refresh token as an OAuth error.
            let code = json["error"].string ?? json["response"]["error"]["code"].string
            let rejectedGrant = [400, 403].contains(status) && ["invalid_grant", "InvalidToken", "unauthorized_client"].contains(code)
            if status == 401 || rejectedGrant {
                throw .authenticationRequired
            }
            throw .http(status: status, message: json["error_description"].string ?? code)
        }
        guard let accessToken = json["access_token"].string, let expiresIn = json["expires_in"].int else {
            throw .malformedResponse("Token refresh response is missing the access token.")
        }
        var refreshed = session
        refreshed.accessToken = accessToken
        refreshed.accessTokenExpiresAt = now.addingTimeInterval(TimeInterval(expiresIn))
        return refreshed
    }
}

enum FormEncoding {
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ items: [URLQueryItem]) -> String {
        items.map { item in
            let name = item.name.addingPercentEncoding(withAllowedCharacters: allowed)!
            let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed)!
            return "\(name)=\(value)"
        }.joined(separator: "&")
    }
}
