import Foundation
import Testing
import AudibleExporterCore
import AudibleExporterPresentation
import TestSupport

@MainActor
@Suite struct SessionViewModelTests {
    let api = MockAudibleAPI()
    let store = InMemoryCredentialStore()

    func makeModel() async -> (SessionViewModel, AuthenticationCoordinator) {
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        let model = SessionViewModel(auth: auth)
        await model.start()
        return (model, auth)
    }

    @Test func signedOutStateEnablesSignInOnly() async {
        let (model, _) = await makeModel()
        #expect(!model.isSignedIn)
        #expect(model.canSignIn)
        #expect(model.canChangeMarketplace)
        #expect(!model.canSignOut)
        #expect(model.pendingLogin == nil)
    }

    @Test func restoresSavedSessionAndMarketplace() async {
        store.stored.withLock { $0 = Fixtures.session(marketplace: .japan) }
        let (model, _) = await makeModel()
        #expect(model.isSignedIn)
        #expect(model.marketplace == .japan)
        #expect(model.canSignOut && !model.canSignIn)
        #expect(model.accountDescription == "Test User · Japan")
    }

    @Test func storageFailureOnRestoreIsShown() async {
        store.failLoad.withLock { $0 = true }
        let (model, _) = await makeModel()
        #expect(model.errorMessage != nil)
        #expect(!model.isSignedIn)
    }

    @Test func signInFlowWithBrowserCallback() async throws {
        api.registerHandler.withLock { $0 = { login, _ in Fixtures.session(marketplace: login.marketplace) } }
        let (model, _) = await makeModel()
        model.marketplace = .uk
        await model.signIn()
        let login = try #require(model.pendingLogin)
        #expect(login.marketplace == .uk)
        #expect(!model.canChangeMarketplace)
        #expect(model.isCallback(Fixtures.callbackURL(marketplace: .uk)))
        #expect(!model.isCallback(URL(string: "https://www.amazon.co.uk/ap/signin")!))

        await model.completeSignIn(with: Fixtures.callbackURL(marketplace: .uk))
        #expect(model.isSignedIn)
        #expect(model.pendingLogin == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func pastedURLFallbackUsesSameCoordinator() async throws {
        api.registerHandler.withLock { $0 = { _, _ in Fixtures.session() } }
        let (model, _) = await makeModel()
        await model.signIn()
        #expect(!model.canSubmitPastedURL)

        model.pastedCallbackURL = "https://www.amazon.com/ap/maplanding?nothing=here"
        #expect(model.canSubmitPastedURL)
        await model.submitPastedURL()
        #expect(model.errorMessage != nil)
        #expect(model.pendingLogin != nil) // still waiting for a usable URL

        model.pastedCallbackURL = "  \(Fixtures.callbackURL().absoluteString)\n"
        await model.submitPastedURL()
        #expect(model.isSignedIn)
        #expect(model.pastedCallbackURL.isEmpty)
    }

    @Test func cancelSignInReturnsToSignedOut() async {
        let (model, _) = await makeModel()
        await model.signIn()
        await model.cancelSignIn()
        #expect(model.pendingLogin == nil)
        #expect(model.canSignIn)
    }

    @Test func signOutClearsSession() async {
        store.stored.withLock { $0 = Fixtures.session() }
        let (model, _) = await makeModel()
        await model.signOut()
        #expect(!model.isSignedIn)
        #expect(store.stored.current == nil)
    }

    @Test func reflectsReauthenticationRequirement() async throws {
        store.stored.withLock { $0 = Fixtures.session(expiresAt: .distantPast) }
        api.refreshHandler.withLock { $0 = { _ in throw ExporterError.authenticationRequired } }
        let (model, auth) = await makeModel()
        _ = try? await auth.validSession()
        try await waitUntil { await model.needsReauthentication }
        #expect(model.canSignIn)
        #expect(model.canSignOut)
    }
}
