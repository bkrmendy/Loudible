import Foundation

/// Audible operations the application needs. Implemented over HTTP by the adapters
/// layer; application tests substitute a mock.
public protocol AudibleAPI: Sendable {
    /// Creates a new device identity, PKCE verifier, login URL, and initial cookies.
    func makeLogin(for marketplace: Marketplace) throws -> PendingLogin
    /// Registers the device using the authorization code from the login callback.
    func register(_ login: PendingLogin, authorizationCode: String) async throws -> AudibleSession
    /// Returns the session with a fresh access token.
    func refresh(_ session: AudibleSession) async throws -> AudibleSession
    /// Fetches one 1-based page of the library held in `marketplace`. The same device
    /// registration is accepted by every store, so it need not be the session's own.
    func libraryPage(_ number: Int, pageSize: Int, marketplace: Marketplace, session: AudibleSession) async throws
        -> LibraryPage
    /// Requests and decrypts a download license from the store that holds the title.
    func license(for asin: String, marketplace: Marketplace, session: AudibleSession) async throws -> ContentLicense
}

/// Persists the signed-in session.
public protocol CredentialStore: Sendable {
    func load() throws -> AudibleSession?
    func save(_ session: AudibleSession) throws
    func delete() throws
}

/// How much of a download has arrived.
public struct TransferProgress: Sendable, Equatable, Codable {
    public var bytesReceived: Int64
    public var bytesExpected: Int64

    public init(bytesReceived: Int64, bytesExpected: Int64) {
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
    }

    /// 0...1; 0 while the size is unknown.
    public var fraction: Double {
        bytesExpected > 0 ? min(max(Double(bytesReceived) / Double(bytesExpected), 0), 1) : 0
    }
}

/// Native recovery state. Resume data is opaque and may become unusable between launches.
public struct DownloadRecovery: Sendable, Equatable, Codable {
    public var resumeData: Data?
    public var progress: TransferProgress?

    public init(resumeData: Data? = nil, progress: TransferProgress? = nil) {
        self.resumeData = resumeData
        self.progress = progress
    }
}

/// Downloads a URL completely to `destination`; interrupted bytes are managed by the adapter.
public protocol FileDownloader: Sendable {
    /// Attempts native resumption, falling back once to `url` if it cannot resume.
    /// Recovery is reported before returning, including on cancellation. A nil token means
    /// the next attempt must restart. Callers decide whether to retain the recovery state.
    func download(
        from url: URL,
        to destination: URL,
        resumeData: Data?,
        recovery: @escaping @Sendable (DownloadRecovery) -> Void,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws
}

extension FileDownloader {
    /// A fresh download nobody intends to resume.
    public func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        try await download(from: url, to: destination, resumeData: nil, recovery: { _ in }, progress: progress)
    }
}

/// Metadata written into the exported file in addition to what the source carries.
public struct BookMetadata: Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var authors: [String]
    public var narrators: [String]
    public var publisher: String?
    public var releaseDate: String?
    public var asin: String

    public init(book: Audiobook) {
        title = book.title
        subtitle = book.subtitle
        authors = book.authors
        narrators = book.narrators
        publisher = book.publisher
        releaseDate = book.releaseDate
        asin = book.asin
    }
}

public struct ConversionRequest: Sendable, Equatable {
    public var input: URL
    public var output: URL
    public var decryption: ContentLicense.Decryption
    public var chapters: [Chapter]
    public var metadata: BookMetadata

    public init(
        input: URL,
        output: URL,
        decryption: ContentLicense.Decryption,
        chapters: [Chapter],
        metadata: BookMetadata) {
        self.input = input
        self.output = output
        self.decryption = decryption
        self.chapters = chapters
        self.metadata = metadata
    }
}

/// Decrypts and remuxes a downloaded file into an M4B at `request.output`.
public protocol AudioConverter: Sendable {
    func convert(_ request: ConversionRequest, progress: @escaping @Sendable (Double) -> Void) async throws
}

public protocol WallClock: Sendable {
    func now() -> Date
}

public protocol RandomSource: Sendable {
    func bytes(count: Int) -> Data
    func uuid() -> UUID
}

public struct SystemClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}

public struct SystemRandom: RandomSource {
    public init() {}

    public func bytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public func uuid() -> UUID { UUID() }
}
