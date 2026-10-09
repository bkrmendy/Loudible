import Foundation

/// Owns the sign-in lifecycle: starting and validating logins, restoring and persisting the
/// session, refreshing access tokens (one refresh at a time), and local sign-out.
public actor AuthenticationCoordinator {
    public enum State: Sendable, Equatable {
        case signedOut
        /// The browser is showing the login page for this attempt.
        case awaitingCallback(PendingLogin)
        /// The callback was accepted and the device is being registered.
        case registering(PendingLogin)
        case signedIn(AudibleSession)
        /// Stored credentials stopped working; the user must sign in again.
        case reauthenticationRequired(Marketplace)

        public var session: AudibleSession? {
            if case .signedIn(let session) = self { session } else { nil }
        }
    }

    public private(set) var state: State = .signedOut {
        didSet {
            guard state != oldValue else { return }
            for continuation in observers.values { continuation.yield(state) }
        }
    }

    /// Set when the session works but could not be saved or removed from storage.
    public private(set) var storageWarning: String?

    private let api: any AudibleAPI
    private let store: any CredentialStore
    private let clock: any WallClock
    private var refreshTask: (session: AudibleSession, task: Task<AudibleSession, any Error>)?
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]

    public init(api: any AudibleAPI, store: any CredentialStore, clock: any WallClock) {
        self.api = api
        self.store = store
        self.clock = clock
    }

    /// Emits the current state, then every change.
    public func stateUpdates() -> AsyncStream<State> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(16))
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        observers[id] = continuation
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: Restoration

    /// Loads stored credentials. Returns the restored session, or nil when there is none.
    @discardableResult
    public func restore() throws(ExporterError) -> AudibleSession? {
        do {
            guard let session = try store.load() else {
                state = .signedOut
                return nil
            }
            state = .signedIn(session)
            return session
        } catch {
            state = .signedOut
            throw .credentialStorage(String(describing: error))
        }
    }

    // MARK: Login

    /// Starts a new sign-in. Any earlier pending sign-in becomes stale.
    public func beginLogin(marketplace: Marketplace) throws -> PendingLogin {
        let login = try api.makeLogin(for: marketplace)
        state = .awaitingCallback(login)
        return login
    }

    public func cancelLogin() {
        switch state {
        case .awaitingCallback, .registering:
            state = .signedOut
        default:
            break
        }
    }

    /// The pending sign-in, if the browser is expected to deliver a callback.
    public var pendingLogin: PendingLogin? {
        if case .awaitingCallback(let login) = state { login } else { nil }
    }

    /// Validates the redirect URL and registers the device.
    ///
    /// A malformed URL leaves the sign-in pending so a corrected URL can be pasted. Once a
    /// callback is accepted, further callbacks are rejected as duplicates.
    public func completeLogin(callbackURL: URL) async throws(ExporterError) -> AudibleSession {
        guard case .awaitingCallback(let login) = state else {
            throw .loginCallback(.noPendingLogin)
        }
        guard !login.isExpired(at: clock.now()) else {
            state = .signedOut
            throw .loginCallback(.expired)
        }
        let code: String
        do {
            code = try LoginCallback.authorizationCode(from: callbackURL, for: login)
        } catch {
            throw .loginCallback(error)
        }

        state = .registering(login)
        let session: AudibleSession
        do {
            session = try await api.register(login, authorizationCode: code)
        } catch {
            // The authorization code is single-use, so a failed registration needs a new login.
            if state == .registering(login) { state = .signedOut }
            throw ExporterError.from(error)
        }
        guard state == .registering(login) else {
            // Cancelled or superseded while registering: discard the result.
            throw .cancelled
        }

        state = .signedIn(session)
        persist(session)
        return session
    }

    // MARK: Session use

    /// Returns a session whose access token is valid, refreshing it if necessary.
    /// Concurrent callers share a single refresh.
    public func validSession() async throws(ExporterError) -> AudibleSession {
        guard case .signedIn(let session) = state else { throw .authenticationRequired }
        guard session.needsRefresh(at: clock.now()) else { return session }

        let task: Task<AudibleSession, any Error>
        if let existing = refreshTask, existing.session.device == session.device {
            task = existing.task
        } else {
            let api = self.api
            task = Task { try await api.refresh(session) }
            refreshTask = (session, task)
        }

        let result: Result<AudibleSession, any Error>
        do {
            result = .success(try await task.value)
        } catch {
            result = .failure(error)
        }
        if refreshTask?.task == task { refreshTask = nil }

        // Signed out, or signed in as another device, while refreshing.
        guard let current = state.session, current.device == session.device else {
            throw .authenticationRequired
        }

        switch result {
        case .success(let refreshed):
            if current != refreshed {
                state = .signedIn(refreshed)
                persist(refreshed)
            }
            return refreshed
        case .failure(let error):
            let exporterError = ExporterError.from(error)
            if exporterError == .authenticationRequired {
                state = .reauthenticationRequired(session.marketplace)
                deleteStoredCredentials()
            }
            throw exporterError
        }
    }

    /// Runs an API call with a valid session. If Audible rejects the credentials, the token
    /// is refreshed and the call retried once; a second rejection requires signing in again.
    public func withValidSession<T: Sendable>(
        _ operation: @Sendable (AudibleSession) async throws -> T
    ) async throws(ExporterError) -> T {
        for attempt in 1...2 {
            let session = try await validSession()
            do {
                return try await operation(session)
            } catch {
                let exporterError = ExporterError.from(error)
                guard exporterError == .authenticationRequired else { throw exporterError }
                // Signed out or signed in again meanwhile: leave the new state alone.
                guard state.session?.device == session.device else { throw .authenticationRequired }
                if attempt == 2 {
                    state = .reauthenticationRequired(session.marketplace)
                    deleteStoredCredentials()
                    throw .authenticationRequired
                }
                invalidateAccessToken()
            }
        }
        throw .authenticationRequired
    }

    /// Forces the next `validSession()` to refresh, e.g. after the API rejected the token.
    public func invalidateAccessToken() {
        guard case .signedIn(var session) = state else { return }
        session.accessTokenExpiresAt = .distantPast
        state = .signedIn(session)
    }

    /// Forgets the session locally. The device registration is not revoked with Audible.
    public func signOut() throws(ExporterError) {
        refreshTask?.task.cancel()
        refreshTask = nil
        state = .signedOut
        storageWarning = nil
        do {
            try store.delete()
        } catch {
            throw .credentialStorage(String(describing: error))
        }
    }

    // MARK: Helpers

    private func persist(_ session: AudibleSession) {
        do {
            try store.save(session)
            storageWarning = nil
        } catch {
            storageWarning = "Signed in, but the credentials could not be saved: \(error)"
        }
    }

    private func deleteStoredCredentials() {
        do {
            try store.delete()
        } catch {
            storageWarning = "Could not remove expired credentials: \(error)"
        }
    }
}
