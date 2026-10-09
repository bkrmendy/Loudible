import Foundation
import AudibleExporterCore

/// A lock-protected value for test doubles shared across tasks.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value { withLock { $0 } }
}

public final class TestClock: WallClock, @unchecked Sendable {
    private let date: Locked<Date>

    public init(_ date: Date = Fixtures.referenceDate) { self.date = Locked(date) }

    public func now() -> Date { date.current }
    public func advance(by interval: TimeInterval) { date.withLock { $0.addTimeInterval(interval) } }
    public func set(_ newDate: Date) { date.withLock { $0 = newDate } }
}

/// Deterministic randomness: bytes count up from `seed`, UUIDs are sequential.
public final class SequentialRandom: RandomSource, @unchecked Sendable {
    private let state: Locked<(byte: UInt8, uuid: UInt64)>

    public init(seed: UInt8 = 0) { state = Locked((seed, 1)) }

    public func bytes(count: Int) -> Data {
        state.withLock { state in
            Data((0..<count).map { _ in
                defer { state.byte &+= 1 }
                return state.byte
            })
        }
    }

    public func uuid() -> UUID {
        state.withLock { state in
            defer { state.uuid += 1 }
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", state.uuid))!
        }
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    public struct Failure: Error, Equatable { public init() {} }

    public let stored: Locked<AudibleSession?>
    public let failLoad = Locked(false)
    public let failSave = Locked(false)
    public let failDelete = Locked(false)
    public let saveCount = Locked(0)

    public init(_ session: AudibleSession? = nil) { stored = Locked(session) }

    public func load() throws -> AudibleSession? {
        if failLoad.current { throw Failure() }
        return stored.current
    }

    public func save(_ session: AudibleSession) throws {
        if failSave.current { throw Failure() }
        stored.withLock { $0 = session }
        saveCount.withLock { $0 += 1 }
    }

    public func delete() throws {
        if failDelete.current { throw Failure() }
        stored.withLock { $0 = nil }
    }
}

/// Scriptable `AudibleAPI`. Each handler defaults to failing so tests state what they use.
public final class MockAudibleAPI: AudibleAPI, @unchecked Sendable {
    public struct Unscripted: Error {}

    public let makeLoginHandler: Locked<@Sendable (Marketplace) throws -> PendingLogin>
    public let registerHandler: Locked<@Sendable (PendingLogin, String) async throws -> AudibleSession>
    public let refreshHandler: Locked<@Sendable (AudibleSession) async throws -> AudibleSession>
    public let libraryHandler: Locked<@Sendable (Int, Int, AudibleSession) async throws -> LibraryPage>
    public let licenseHandler: Locked<@Sendable (String, AudibleSession) async throws -> ContentLicense>

    public let refreshCount = Locked(0)
    public let registerCount = Locked(0)
    public let requestedPages = Locked<[Int]>([])
    public let requestedLicenses = Locked<[String]>([])

    public init() {
        makeLoginHandler = Locked { marketplace in Fixtures.pendingLogin(marketplace: marketplace) }
        registerHandler = Locked { _, _ in throw Unscripted() }
        refreshHandler = Locked { _ in throw Unscripted() }
        libraryHandler = Locked { _, _, _ in throw Unscripted() }
        licenseHandler = Locked { _, _ in throw Unscripted() }
    }

    public func makeLogin(for marketplace: Marketplace) throws -> PendingLogin {
        try makeLoginHandler.current(marketplace)
    }

    public func register(_ login: PendingLogin, authorizationCode: String) async throws -> AudibleSession {
        registerCount.withLock { $0 += 1 }
        return try await registerHandler.current(login, authorizationCode)
    }

    public func refresh(_ session: AudibleSession) async throws -> AudibleSession {
        refreshCount.withLock { $0 += 1 }
        return try await refreshHandler.current(session)
    }

    public func libraryPage(_ number: Int, pageSize: Int, session: AudibleSession) async throws -> LibraryPage {
        requestedPages.withLock { $0.append(number) }
        return try await libraryHandler.current(number, pageSize, session)
    }

    public func license(for asin: String, session: AudibleSession) async throws -> ContentLicense {
        requestedLicenses.withLock { $0.append(asin) }
        return try await licenseHandler.current(asin, session)
    }
}

/// Writes `contents` to the destination unless the handler throws.
public final class MockDownloader: FileDownloader, @unchecked Sendable {
    public let handler: Locked<@Sendable (URL, URL) async throws -> Void>
    public let downloads = Locked<[(source: URL, destination: URL)]>([])

    public init(contents: Data = Data("encrypted".utf8)) {
        handler = Locked { _, destination in try contents.write(to: destination) }
    }

    public func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        downloads.withLock { $0.append((url, destination)) }
        progress(0.5)
        try await handler.current(url, destination)
        progress(1)
    }
}

/// Writes a fake M4B to the requested output unless the handler throws.
public final class MockConverter: AudioConverter, @unchecked Sendable {
    public let handler: Locked<@Sendable (ConversionRequest) async throws -> Void>
    public let requests = Locked<[ConversionRequest]>([])

    public init() {
        handler = Locked { request in try Data("m4b:\(request.metadata.asin)".utf8).write(to: request.output) }
    }

    public func convert(_ request: ConversionRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        requests.withLock { $0.append(request) }
        progress(0.5)
        try await handler.current(request)
        progress(1)
    }
}
