import Foundation
import Testing
@testable import LoudibleAdapters
import LoudibleCore
import TestSupport

@Suite struct PKCETests {
    /// RFC 7636, Appendix B.
    @Test func matchesRFC7636Example() {
        let octets: [UInt8] = [
            116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
            22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121,
        ]
        let verifier = PKCE.codeVerifier(from: Data(octets))
        #expect(verifier == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(PKCE.codeChallenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
}

@Suite struct LoginFactoryTests {
    private func makeLogin(_ marketplace: Marketplace = .us) -> PendingLogin {
        AudibleLoginFactory(random: SequentialRandom(), clock: TestClock()).makeLogin(for: marketplace)
    }

    @Test func keepsVerifierAndDeviceTogether() throws {
        let login = makeLogin()
        #expect(login.device.serial == "00000000000000000000000000000001")
        #expect(login.device.deviceType == "A2CZJZGLK2JJVM")
        #expect(login.codeVerifier == PKCE.codeVerifier(from: Data((0..<32).map { UInt8($0) })))
        #expect(login.createdAt == Fixtures.referenceDate)

        let query = URLRequest(url: login.loginURL).queryItems
        #expect(query["openid.oa2.client_id"] == "device:\(login.device.clientID)")
        #expect(query["openid.oa2.code_challenge"] == PKCE.codeChallenge(for: login.codeVerifier))
        #expect(query["openid.oa2.code_challenge_method"] == "S256")
    }

    @Test(arguments: Marketplace.all)
    func buildsMarketplaceSpecificLoginURL(marketplace: Marketplace) throws {
        let login = makeLogin(marketplace)
        let components = try #require(URLComponents(url: login.loginURL, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "www.amazon.\(marketplace.domain)")
        #expect(components.path == "/ap/signin")
        let query = URLRequest(url: login.loginURL).queryItems
        #expect(query["openid.assoc_handle"] == "amzn_audible_ios_\(marketplace.id)")
        #expect(query["marketPlaceId"] == marketplace.marketplaceID)
        #expect(query["openid.return_to"] == "https://www.amazon.\(marketplace.domain)/ap/maplanding")
        #expect(query["openid.oa2.response_type"] == "code")
        #expect(query["openid.oa2.scope"] == "device_auth_access")
        #expect(query["pageId"] == "amzn_audible_ios")
        #expect(login.cookies.allSatisfy { $0.domain == ".amazon.\(marketplace.domain)" })
    }

    @Test func setsInitialCookiesAndUserAgent() throws {
        let login = makeLogin()
        let cookies = Dictionary(uniqueKeysWithValues: login.cookies.map { ($0.name, $0.value) })
        #expect(Set(cookies.keys) == ["frc", "map-md", "amzn-app-id"])
        #expect(cookies["amzn-app-id"] == "MAPiOSLib/6.0/ToHideRetailLink")
        #expect(!(cookies["frc"]?.hasSuffix("=") ?? true))
        #expect(Data(base64Encoded: padded(cookies["frc"]!))?.count == 313)

        let mapMD = try #require(Data(base64Encoded: padded(cookies["map-md"]!)))
        let metadata = try #require(JSONSerialization.jsonObject(with: mapMD) as? [String: Any])
        let app = try #require(metadata["app_identifier"] as? [String: String])
        #expect(app["bundle_id"] == "com.audible.iphone")
        #expect(login.userAgent?.contains("iPhone") == true)
    }

    private func padded(_ base64: String) -> String {
        base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
    }

    @Test func eachLoginGetsFreshIdentity() {
        let factory = AudibleLoginFactory(random: SequentialRandom(), clock: TestClock())
        let first = factory.makeLogin(for: .us), second = factory.makeLogin(for: .us)
        #expect(first.id != second.id)
        #expect(first.device != second.device)
        #expect(first.codeVerifier != second.codeVerifier)
    }
}

@Suite struct RequestSignerTests {
    struct Vector: Decodable {
        let method: String, path: String, timestamp: String, body: String, signature: String
    }

    struct Vectors: Decodable {
        let adp_token: String
        let vectors: [Vector]
    }

    @Test(arguments: ["synthetic-device-key.pem", "synthetic-device-key-pkcs8.pem"])
    func matchesOpenSSLSignatures(keyFile: String) throws {
        let fixture = try JSONDecoder().decode(Vectors.self, from: Fixture.data("signing-vectors.json"))
        let signer = try RequestSigner(adpToken: fixture.adp_token, privateKeyPEM: Fixture.string(keyFile))
        for vector in fixture.vectors {
            let signature = try signer.signature(
                method: vector.method, pathAndQuery: vector.path, timestamp: vector.timestamp, body: Data(vector.body.utf8)
            )
            #expect(signature == vector.signature)
        }
    }

    @Test func signsRequestHeaders() throws {
        let fixture = try JSONDecoder().decode(Vectors.self, from: Fixture.data("signing-vectors.json"))
        let signer = try RequestSigner(adpToken: fixture.adp_token, privateKeyPEM: Fixture.string("synthetic-device-key.pem"))
        var request = URLRequest(url: URL(string: "https://api.audible.com/1.0/library?num_results=50&page=1")!)
        let date = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!
        try signer.sign(&request, date: date)

        #expect(request.value(forHTTPHeaderField: "x-adp-token") == fixture.adp_token)
        #expect(request.value(forHTTPHeaderField: "x-adp-alg") == "SHA256withRSA:1.0")
        #expect(request.value(forHTTPHeaderField: "x-adp-signature") == "\(fixture.vectors[0].signature):2027-01-15T08:00:00.000000Z")
    }

    @Test func formatsMicrosecondTimestamps() {
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        #expect(RequestSigner.timestamp(date) == "2027-01-15T08:00:00.250000Z")
    }

    @Test func pathIncludesEncodedQuery() {
        let url = URL(string: "https://api.audible.com/1.0/library?response_groups=a%2Cb&page=2")!
        #expect(RequestSigner.pathAndQuery(of: url) == "/1.0/library?response_groups=a%2Cb&page=2")
        #expect(RequestSigner.pathAndQuery(of: URL(string: "https://x.test/a/b")!) == "/a/b")
    }

    @Test func rejectsInvalidKeys() {
        #expect(throws: RequestSigner.SigningError.invalidPEM) {
            try RequestSigner(adpToken: "t", privateKeyPEM: "not a key")
        }
        #expect(throws: RequestSigner.SigningError.unsupportedKeyFormat) {
            try RequestSigner(adpToken: "t", privateKeyPEM: "-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----")
        }
        #expect(throws: RequestSigner.SigningError.self) {
            try RequestSigner(adpToken: "t", privateKeyPEM: "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----")
        }
    }
}

@Suite struct DeviceRegistrationTests {
    private let login = Fixtures.pendingLogin(marketplace: .uk)

    @Test func buildsRegistrationRequest() throws {
        let request = try DeviceRegistration.request(for: login, authorizationCode: "code-123")
        #expect(request.url?.absoluteString == "https://api.amazon.co.uk/auth/register")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "x-amzn-identity-auth-domain") == "api.amazon.co.uk")

        let body = try #require(request.jsonBody)
        let auth = try #require(body["auth_data"] as? [String: String])
        #expect(auth["authorization_code"] == "code-123")
        #expect(auth["code_verifier"] == login.codeVerifier)
        #expect(auth["client_id"] == login.device.clientID)
        #expect(auth["code_algorithm"] == "SHA-256")
        let registration = try #require(body["registration_data"] as? [String: String])
        #expect(registration["device_serial"] == login.device.serial)
        #expect(registration["device_type"] == "A2CZJZGLK2JJVM")
        #expect(body["requested_token_type"] as? [String] == ["bearer", "mac_dms", "website_cookies", "store_authentication_cookie"])
        #expect((body["cookies"] as? [String: Any])?["domain"] as? String == ".amazon.co.uk")
    }

    @Test func parsesSuccessfulRegistration() throws {
        let session = try DeviceRegistration.session(
            from: Fixture.data("register-success.json"), status: 200, login: login, receivedAt: Fixtures.referenceDate
        )
        #expect(session.marketplace == .uk)
        #expect(session.device == login.device)
        #expect(session.customerID == "amzn1.account.SYNTHETIC")
        #expect(session.customerName == "Test")
        #expect(session.accessToken == "Atna|synthetic-access")
        #expect(session.refreshToken == "Atnr|synthetic-refresh")
        #expect(session.accessTokenExpiresAt == Fixtures.referenceDate.addingTimeInterval(3600))
        #expect(session.adpToken.hasPrefix("{enc:synthetic-adp}"))
        #expect(session.devicePrivateKey.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"))
    }

    @Test func reportsServerErrors() throws {
        #expect(throws: ExporterError.http(status: 400, message: "The authorization code is invalid or expired.")) {
            try DeviceRegistration.session(from: Fixture.data("register-error.json"), status: 400, login: login, receivedAt: Fixtures.referenceDate)
        }
    }

    @Test func rejectsResponsesWithoutTokens() throws {
        var json = try Fixture.json("register-success.json")
        var response = json["response"] as! [String: Any], success = response["success"] as! [String: Any]
        var tokens = success["tokens"] as! [String: Any]
        tokens["mac_dms"] = nil
        success["tokens"] = tokens; response["success"] = success; json["response"] = response
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: ExporterError.self) {
            try DeviceRegistration.session(from: data, status: 200, login: login, receivedAt: Fixtures.referenceDate)
        }
        #expect(throws: ExporterError.self) {
            try DeviceRegistration.session(from: Data("<html>".utf8), status: 200, login: login, receivedAt: Fixtures.referenceDate)
        }
    }

    @Test func rejectsRegistrationOfDifferentDevice() throws {
        let other = PendingLogin(
            id: login.id, marketplace: .uk, device: DeviceIdentity(serial: "FFFF"), codeVerifier: "v",
            loginURL: login.loginURL, cookies: [], createdAt: login.createdAt
        )
        #expect(throws: ExporterError.self) {
            try DeviceRegistration.session(from: Fixture.data("register-success.json"), status: 200, login: other, receivedAt: Fixtures.referenceDate)
        }
    }

    @Test func registersThroughTransport() async throws {
        let transport = MockTransport(status: 200, body: try Fixture.data("register-success.json"))
        let api = AudibleHTTPAPI(transport: transport, random: SequentialRandom(), clock: TestClock())
        let session = try await api.register(login, authorizationCode: "abc")
        #expect(session.accessToken == "Atna|synthetic-access")
        #expect(transport.requests.current.count == 1)
    }

    @Test func mapsTransportFailures() async throws {
        let transport = MockTransport { _ in throw URLError(.notConnectedToInternet) }
        let api = AudibleHTTPAPI(transport: transport, random: SequentialRandom(), clock: TestClock())
        await #expect(throws: ExporterError.self) { try await api.register(login, authorizationCode: "abc") }
    }
}

@Suite struct TokenRefreshTests {
    private let session = Fixtures.session(marketplace: .germany)

    @Test func buildsFormEncodedRefreshRequest() {
        let request = TokenRefresh.request(for: session)
        #expect(request.url?.absoluteString == "https://api.amazon.de/auth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.formBody == [
            "app_name": "Audible",
            "app_version": "3.56.2",
            "source_token": "Atnr|synthetic-refresh",
            "requested_token_type": "access_token",
            "source_token_type": "refresh_token",
        ])
        #expect(String(decoding: request.httpBody!, as: UTF8.self).contains("Atnr%7Csynthetic-refresh"))
    }

    @Test func appliesRefreshedToken() throws {
        let now = Fixtures.referenceDate.addingTimeInterval(7200)
        let refreshed = try TokenRefresh.session(byApplying: Fixture.data("refresh-success.json"), status: 200, to: session, receivedAt: now)
        #expect(refreshed.accessToken == "Atna|synthetic-refreshed")
        #expect(refreshed.accessTokenExpiresAt == now.addingTimeInterval(3600))
        #expect(refreshed.refreshToken == session.refreshToken)
        #expect(refreshed.device == session.device)
    }

    @Test func invalidGrantRequiresReauthentication() throws {
        #expect(throws: ExporterError.authenticationRequired) {
            try TokenRefresh.session(byApplying: Fixture.data("refresh-invalid-grant.json"), status: 400, to: session, receivedAt: Fixtures.referenceDate)
        }
        #expect(throws: ExporterError.authenticationRequired) {
            try TokenRefresh.session(byApplying: Data(), status: 401, to: session, receivedAt: Fixtures.referenceDate)
        }
    }

    @Test func serverFailureIsNotReauthentication() {
        #expect(throws: ExporterError.http(status: 503, message: nil)) {
            try TokenRefresh.session(byApplying: Data(), status: 503, to: session, receivedAt: Fixtures.referenceDate)
        }
        #expect(throws: ExporterError.self) {
            try TokenRefresh.session(byApplying: Data("{}".utf8), status: 200, to: session, receivedAt: Fixtures.referenceDate)
        }
    }
}

@Suite struct KeychainCredentialStoreTests {
    @Test func savesLoadsAndDeletesInDedicatedItem() throws {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        #expect(try store.load() == nil)

        let session = Fixtures.session()
        try store.save(session)
        #expect(keychain.lastQuery.current[kSecAttrService as String] as? String == "Loudible.AudibleSession")
        #expect(keychain.lastQuery.current[kSecClass as String] as! CFString == kSecClassGenericPassword)
        #expect(try store.load() == session)

        var updated = session
        updated.accessToken = "new"
        try store.save(updated)
        #expect(try store.load() == updated)
        #expect(keychain.items.current.count == 1)

        try store.delete()
        #expect(try store.load() == nil)
        try store.delete() // deleting nothing is fine
    }

    @Test func surfacesKeychainErrors() throws {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        keychain.forcedStatus.withLock { $0 = ["copy": errSecInteractionNotAllowed] }
        #expect(throws: KeychainCredentialStore.KeychainError.self) { try store.load() }

        keychain.forcedStatus.withLock { $0 = ["add": errSecAuthFailed] }
        #expect(throws: KeychainCredentialStore.KeychainError.self) { try store.save(Fixtures.session()) }

        keychain.forcedStatus.withLock { $0 = ["update": errSecAuthFailed] }
        #expect(throws: KeychainCredentialStore.KeychainError.self) { try store.save(Fixtures.session()) }

        keychain.forcedStatus.withLock { $0 = ["delete": errSecAuthFailed] }
        #expect(throws: KeychainCredentialStore.KeychainError.self) { try store.delete() }
    }

    @Test func reportsCorruptItems() throws {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        _ = keychain.add([
            kSecAttrService as String: KeychainCredentialStore.defaultService,
            kSecAttrAccount as String: "default",
            kSecValueData as String: Data("not json".utf8),
        ])
        #expect(throws: KeychainCredentialStore.CorruptItem.self) { try store.load() }
    }
}
