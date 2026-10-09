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
    /// Fetches one 1-based page of the library.
    func libraryPage(_ number: Int, pageSize: Int, session: AudibleSession) async throws -> LibraryPage
    /// Requests and decrypts a download license.
    func license(for asin: String, session: AudibleSession) async throws -> ContentLicense
}

/// Persists the signed-in session.
public protocol CredentialStore: Sendable {
    func load() throws -> AudibleSession?
    func save(_ session: AudibleSession) throws
    func delete() throws
}

/// Downloads a URL completely to `destination`. Must not leave a file behind on failure.
public protocol FileDownloader: Sendable {
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
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

    public init(input: URL, output: URL, decryption: ContentLicense.Decryption, chapters: [Chapter], metadata: BookMetadata) {
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
