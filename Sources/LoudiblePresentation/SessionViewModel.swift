import Foundation
import Observation
import LoudibleCore

/// Sign-in state and actions for the window's account controls and login sheet.
@MainActor
@Observable
public final class SessionViewModel {
    public var marketplace: Marketplace = .us
    public private(set) var authState: AuthenticationCoordinator.State = .signedOut
    /// Set while the login browser should be shown.
    public private(set) var pendingLogin: PendingLogin?
    /// Text field for the external-browser fallback: the final URL pasted by the user.
    public var pastedCallbackURL = ""
    public private(set) var isWorking = false
    public var errorMessage: String?
    /// False until `start()` has tried to restore saved credentials, so the window does not
    /// offer to sign in before it knows whether a session exists.
    public private(set) var hasRestored = false

    private let auth: AuthenticationCoordinator
    @ObservationIgnored private var observation: Task<Void, Never>?

    public init(auth: AuthenticationCoordinator) {
        self.auth = auth
    }

    /// Restores saved credentials and starts mirroring the coordinator's state.
    public func start() async {
        defer { hasRestored = true }
        if observation == nil {
            let updates = await auth.stateUpdates()
            observation = Task { [weak self] in
                for await state in updates {
                    self?.apply(state)
                }
            }
        }
        do {
            if let session = try await auth.restore() {
                marketplace = session.marketplace
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        apply(await auth.state)
    }

    private func apply(_ state: AuthenticationCoordinator.State) {
        authState = state
        switch state {
        case .awaitingCallback(let login):
            pendingLogin = login
        case .signedIn(let session):
            pendingLogin = nil
            marketplace = session.marketplace
        case .reauthenticationRequired(let marketplace):
            pendingLogin = nil
            self.marketplace = marketplace
        case .signedOut, .registering:
            pendingLogin = nil
        }
    }

    // MARK: Derived state

    public var session: AudibleSession? { authState.session }
    public var isSignedIn: Bool { session != nil }
    public var needsReauthentication: Bool {
        if case .reauthenticationRequired = authState { true } else { false }
    }
    public var isRegistering: Bool {
        if case .registering = authState { true } else { false }
    }
    public var canSignIn: Bool { !isWorking && !isSignedIn && !isRegistering }
    public var canSignOut: Bool { !isWorking && (isSignedIn || needsReauthentication) }
    public var canChangeMarketplace: Bool { canSignIn && pendingLogin == nil }
    public var canSubmitPastedURL: Bool {
        pendingLogin != nil && !isWorking && !pastedCallbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var accountDescription: String? {
        session.map { "\($0.customerName ?? "Signed in") · \($0.marketplace.name)" }
    }

    // MARK: Actions

    public func signIn() async {
        errorMessage = nil
        pastedCallbackURL = ""
        do {
            pendingLogin = try await auth.beginLogin(marketplace: marketplace)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// True when the embedded browser should stop and hand this URL to `completeSignIn`.
    public func isCallback(_ url: URL) -> Bool {
        guard let pendingLogin else { return false }
        return LoginCallback.isCallback(url, for: pendingLogin)
    }

    public func completeSignIn(with url: URL) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await auth.completeLogin(callbackURL: url)
            pastedCallbackURL = ""
            if let warning = await auth.storageWarning { errorMessage = warning }
        } catch {
            errorMessage = error.localizedDescription
        }
        apply(await auth.state)
    }

    public func submitPastedURL() async {
        let text = pastedCallbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text) else {
            errorMessage = ExporterError.loginCallback(.malformedURL).localizedDescription
            return
        }
        await completeSignIn(with: url)
    }

    public func cancelSignIn() async {
        await auth.cancelLogin()
        apply(await auth.state)
    }

    public func signOut() async {
        errorMessage = nil
        do {
            try await auth.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
        apply(await auth.state)
    }
}
