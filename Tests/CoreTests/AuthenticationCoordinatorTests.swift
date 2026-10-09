import Foundation
import Testing
import AudibleExporterCore
import TestSupport

@Suite struct AuthenticationCoordinatorTests {
    let api = MockAudibleAPI()
    let store = InMemoryCredentialStore()
    let clock = TestClock()

    func coordinator() -> AuthenticationCoordinator {
        AuthenticationCoordinator(api: api, store: store, clock: clock)
    }

    func scriptRegistration(_ session: AudibleSession = Fixtures.session()) {
        api.registerHandler.withLock { $0 = { _, _ in session } }
    }

    // MARK: Restoration

    @Test func restoresStoredSession() async throws {
        store.stored.withLock { $0 = Fixtures.session() }
        let auth = coordinator()
        #expect(try await auth.restore() == Fixtures.session())
        #expect(await auth.state == .signedIn(Fixtures.session()))
    }

    @Test func restoreWithoutCredentialsIsSignedOut() async throws {
        let auth = coordinator()
        #expect(try await auth.restore() == nil)
        #expect(await auth.state == .signedOut)
    }

    @Test func restoreStorageErrorIsReportedAndSignedOut() async {
        store.failLoad.withLock { $0 = true }
        let auth = coordinator()
        await #expect(throws: ExporterError.self) { try await auth.restore() }
        #expect(await auth.state == .signedOut)
    }

    // MARK: Login

    @Test func completesLoginAndPersistsSession() async throws {
        scriptRegistration()
        let auth = coordinator()
        let login = try await auth.beginLogin(marketplace: .us)
        #expect(await auth.state == .awaitingCallback(login))

        let session = try await auth.completeLogin(callbackURL: Fixtures.callbackURL(code: "the-code"))
        #expect(session == Fixtures.session())
        #expect(await auth.state == .signedIn(session))
        #expect(store.stored.current == session)
        #expect(api.registerCount.current == 1)
    }

    @Test func passesPendingVerifierAndCodeToRegistration() async throws {
        let received = Locked<(PendingLogin, String)?>(nil)
        api.registerHandler.withLock { $0 = { login, code in received.withLock { $0 = (login, code) }; return Fixtures.session() } }
        let auth = coordinator()
        let login = try await auth.beginLogin(marketplace: .us)
        _ = try await auth.completeLogin(callbackURL: Fixtures.callbackURL(code: "abc"))
        #expect(received.current?.0 == login)
        #expect(received.current?.1 == "abc")
    }

    @Test func rejectsDuplicateCallback() async throws {
        scriptRegistration()
        let auth = coordinator()
        _ = try await auth.beginLogin(marketplace: .us)
        _ = try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        await #expect(throws: ExporterError.loginCallback(.noPendingLogin)) {
            try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        }
        #expect(api.registerCount.current == 1)
    }

    @Test func rejectsConcurrentDuplicateCallbackWhileRegistering() async throws {
        let gate = AsyncGate()
        api.registerHandler.withLock { $0 = { _, _ in await gate.wait(); return Fixtures.session() } }
        let auth = coordinator()
        _ = try await auth.beginLogin(marketplace: .us)
        let first = Task { try await auth.completeLogin(callbackURL: Fixtures.callbackURL()) }
        try await waitUntil { if case .registering = await auth.state { true } else { false } }

        await #expect(throws: ExporterError.loginCallback(.noPendingLogin)) {
            try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        }
        await gate.open()
        _ = try await first.value
        #expect(api.registerCount.current == 1)
    }

    @Test func callbackWithoutLoginIsRejected() async {
        let auth = coordinator()
        await #expect(throws: ExporterError.loginCallback(.noPendingLogin)) {
            try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        }
    }

    @Test func callbackAfterCancelIsStale() async throws {
        let auth = coordinator()
        _ = try await auth.beginLogin(marketplace: .us)
        await auth.cancelLogin()
        #expect(await auth.state == .signedOut)
        await #expect(throws: ExporterError.loginCallback(.noPendingLogin)) {
            try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        }
    }

    @Test func expiredLoginIsRejected() async throws {
        let auth = coordinator()
        _ = try await auth.beginLogin(marketplace: .us)
        clock.advance(by: PendingLogin.lifetime + 1)
        await #expect(throws: ExporterError.loginCallback(.expired)) {
            try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        }
        #expect(await auth.state == .signedOut)
        #expect(api.registerCount.current == 0)
    }

    @Test func newLoginSupersedesOldOne() async throws {
        let ids = Locked(0)
        api.makeLoginHandler.withLock {
            $0 = { marketplace in
                let n = ids.withLock { $0 += 1; return $0 }
                return Fixtures.pendingLogin(marketplace: marketplace, id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!)
            }
        }
        let received = Locked<PendingLogin?>(nil)
        api.registerHandler.withLock { $0 = { login, _ in received.withLock { $0 = login }; return Fixtures.session(marketplace: .uk) } }
        let auth = coordinator()
        _ = try await auth.beginLogin(marketplace: .us)
        let second = try await auth.beginLogin(marketplace: .uk)

        // A US callback no longer matches the pending UK login.
        await #expect(throws: ExporterError.loginCallback(.unexpectedHost("www.amazon.com"))) {
            try await auth.completeLogin(callbackURL: Fixtures.callbackURL(marketplace: .us))
        }
        _ = try await auth.completeLogin(callbackURL: Fixtures.callbackURL(marketplace: .uk))
        #expect(received.current == second)
    }

    @Test(arguments: [
        ("http://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=x", LoginCallbackError.malformedURL),
        ("https://www.amazon.evil.com/ap/maplanding?openid.oa2.authorization_code=x", .unexpectedHost("www.amazon.evil.com")),
        ("https://www.amazon.com/ap/signin?openid.oa2.authorization_code=x", .unexpectedPath("/ap/signin")),
        ("https://www.amazon.com/ap/maplanding?other=1", .missingAuthorizationCode),
        ("https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=", .missingAuthorizationCode),
        ("https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=a&openid.oa2.authorization_code=b", .missingAuthorizationCode),
        ("not a url at all", .malformedURL),
    ])
    func malformedCallbackKeepsLoginPending(url: String, expected: LoginCallbackError) async throws {
        let auth = coordinator()
        let login = try await auth.beginLogin(marketplace: .us)
        let callback = URL(string: url) ?? URL(string: "about:blank")!
        await #expect(throws: ExporterError.loginCallback(expected)) {
            try await auth.completeLogin(callbackURL: callback)
        }
        #expect(await auth.state == .awaitingCallback(login))
        #expect(api.registerCount.current == 0)
    }

    @Test func recognisesCallbackForBrowserInterception() {
        let login = Fixtures.pendingLogin(marketplace: .japan)
        #expect(LoginCallback.isCallback(URL(string: "https://www.amazon.co.jp/ap/maplanding?x=1")!, for: login))
        #expect(!LoginCallback.isCallback(URL(string: "https://www.amazon.co.jp/ap/signin")!, for: login))
        #expect(!LoginCallback.isCallback(URL(string: "https://www.amazon.com/ap/maplanding")!, for: login))
    }

    @Test func registrationFailureRequiresNewLogin() async throws {
        api.registerHandler.withLock { $0 = { _, _ in throw ExporterError.http(status: 400, message: "bad code") } }
        let auth = coordinator()
        _ = try await auth.beginLogin(marketplace: .us)
        await #expect(throws: ExporterError.http(status: 400, message: "bad code")) {
            try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        }
        #expect(await auth.state == .signedOut)
        #expect(store.stored.current == nil)
    }

    @Test func cancellingDuringRegistrationDiscardsResult() async throws {
        let gate = AsyncGate()
        api.registerHandler.withLock { $0 = { _, _ in await gate.wait(); return Fixtures.session() } }
        let auth = coordinator()
        _ = try await auth.beginLogin(marketplace: .us)
        let completion = Task { try await auth.completeLogin(callbackURL: Fixtures.callbackURL()) }
        try await waitUntil { if case .registering = await auth.state { true } else { false } }
        await auth.cancelLogin()
        await gate.open()

        await #expect(throws: ExporterError.cancelled) { try await completion.value }
        #expect(await auth.state == .signedOut)
        #expect(store.stored.current == nil)
    }

    @Test func saveFailureKeepsSessionWithWarning() async throws {
        scriptRegistration()
        store.failSave.withLock { $0 = true }
        let auth = coordinator()
        _ = try await auth.beginLogin(marketplace: .us)
        _ = try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        #expect(await auth.state.session != nil)
        #expect(await auth.storageWarning != nil)
    }

    // MARK: Refresh

    @Test func validSessionWithoutSignInRequiresAuthentication() async {
        await #expect(throws: ExporterError.authenticationRequired) { try await coordinator().validSession() }
    }

    @Test func freshTokenIsReturnedWithoutRefresh() async throws {
        store.stored.withLock { $0 = Fixtures.session() }
        let auth = coordinator()
        try await auth.restore()
        #expect(try await auth.validSession() == Fixtures.session())
        #expect(api.refreshCount.current == 0)
    }

    @Test func expiredTokenIsRefreshedAndPersisted() async throws {
        let expired = Fixtures.session(expiresAt: Fixtures.referenceDate.addingTimeInterval(-10))
        let refreshed = Fixtures.session(accessToken: "new", expiresAt: Fixtures.referenceDate.addingTimeInterval(3600))
        store.stored.withLock { $0 = expired }
        api.refreshHandler.withLock { $0 = { _ in refreshed } }
        let auth = coordinator()
        try await auth.restore()
        #expect(try await auth.validSession() == refreshed)
        #expect(await auth.state == .signedIn(refreshed))
        #expect(store.stored.current == refreshed)
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let gate = AsyncGate()
        store.stored.withLock { $0 = Fixtures.session(expiresAt: .distantPast) }
        api.refreshHandler.withLock { $0 = { _ in await gate.wait(); return Fixtures.session(accessToken: "new") } }
        let auth = coordinator()
        try await auth.restore()

        let callers = (0..<20).map { _ in Task { try await auth.validSession() } }
        try await waitUntil { self.api.refreshCount.current == 1 }
        await gate.open()
        for caller in callers {
            #expect(try await caller.value.accessToken == "new")
        }
        #expect(api.refreshCount.current == 1)
    }

    @Test func rejectedRefreshRequiresReauthenticationAndClearsCredentials() async throws {
        store.stored.withLock { $0 = Fixtures.session(expiresAt: .distantPast) }
        api.refreshHandler.withLock { $0 = { _ in throw ExporterError.authenticationRequired } }
        let auth = coordinator()
        try await auth.restore()
        await #expect(throws: ExporterError.authenticationRequired) { try await auth.validSession() }
        #expect(await auth.state == .reauthenticationRequired(.us))
        #expect(store.stored.current == nil)
    }

    @Test func transientRefreshFailureKeepsSession() async throws {
        store.stored.withLock { $0 = Fixtures.session(expiresAt: .distantPast) }
        api.refreshHandler.withLock { $0 = { _ in throw URLError(.timedOut) } }
        let auth = coordinator()
        try await auth.restore()
        await #expect(throws: ExporterError.self) { try await auth.validSession() }
        #expect(await auth.state.session != nil)
        #expect(store.stored.current != nil)
    }

    @Test func invalidatedTokenIsRefreshedNextTime() async throws {
        store.stored.withLock { $0 = Fixtures.session() }
        api.refreshHandler.withLock { $0 = { _ in Fixtures.session(accessToken: "new") } }
        let auth = coordinator()
        try await auth.restore()
        await auth.invalidateAccessToken()
        #expect(try await auth.validSession().accessToken == "new")
        #expect(api.refreshCount.current == 1)
    }

    @Test func signOutDuringRefreshDoesNotResurrectSession() async throws {
        let gate = AsyncGate()
        store.stored.withLock { $0 = Fixtures.session(expiresAt: .distantPast) }
        api.refreshHandler.withLock { $0 = { _ in await gate.wait(); return Fixtures.session(accessToken: "new") } }
        let auth = coordinator()
        try await auth.restore()
        let caller = Task { try await auth.validSession() }
        try await waitUntil { self.api.refreshCount.current == 1 }
        try await auth.signOut()
        await gate.open()
        await #expect(throws: ExporterError.authenticationRequired) { try await caller.value }
        #expect(await auth.state == .signedOut)
        #expect(store.stored.current == nil)
    }

    // MARK: Sign-out

    @Test func signOutRemovesLocalCredentials() async throws {
        store.stored.withLock { $0 = Fixtures.session() }
        let auth = coordinator()
        try await auth.restore()
        try await auth.signOut()
        #expect(await auth.state == .signedOut)
        #expect(store.stored.current == nil)
    }

    @Test func signOutStorageErrorIsReportedButSignsOut() async throws {
        store.stored.withLock { $0 = Fixtures.session() }
        store.failDelete.withLock { $0 = true }
        let auth = coordinator()
        try await auth.restore()
        await #expect(throws: ExporterError.self) { try await auth.signOut() }
        #expect(await auth.state == .signedOut)
    }

    @Test func publishesStateUpdates() async throws {
        scriptRegistration()
        let auth = coordinator()
        let updates = await auth.stateUpdates()
        let collected = Task {
            var states: [AuthenticationCoordinator.State] = []
            for await state in updates {
                states.append(state)
                if state.session != nil { break }
            }
            return states
        }
        let login = try await auth.beginLogin(marketplace: .us)
        _ = try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        #expect(await collected.value == [.signedOut, .awaitingCallback(login), .registering(login), .signedIn(Fixtures.session())])
    }
}
