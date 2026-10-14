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
    func libraryPage(_ number: Int, pageSize: Int, marketplace: Marketplace, session: AudibleSession) async throws -> LibraryPage
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
public struct TransferProgress: Sendable, Equatable {
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

/// Identifies one version of a remote file, so bytes of two versions are never joined.
public enum DownloadValidator: Sendable, Equatable, Codable {
    case etag(String)
    case lastModified(String)
    /// The server sent neither; only the total length can be compared.
    case none
}

/// Where an earlier attempt left off. Only the first `committedLength` bytes of the file are
/// known to be on disk; anything after them may not have survived a crash or power loss.
public struct ResumePoint: Sendable, Equatable {
    public var committedLength: Int64
    public var expectedLength: Int64
    public var validator: DownloadValidator

    public init(committedLength: Int64, expectedLength: Int64, validator: DownloadValidator) {
        self.committedLength = committedLength
        self.expectedLength = expectedLength
        self.validator = validator
    }
}

/// The state of a download as of its last flush to disk: what is needed to continue it later.
public struct DownloadCheckpoint: Sendable, Equatable, Codable {
    /// 0 when the server did not announce the size; such a download cannot be resumed.
    public var expectedLength: Int64
    public var validator: DownloadValidator
    public var committedLength: Int64

    public init(expectedLength: Int64, validator: DownloadValidator, committedLength: Int64) {
        self.expectedLength = expectedLength
        self.validator = validator
        self.committedLength = committedLength
    }

    public var resumePoint: ResumePoint {
        ResumePoint(committedLength: committedLength, expectedLength: expectedLength, validator: validator)
    }
}

/// Downloads a URL completely to `destination`.
public protocol FileDownloader: Sendable {
    /// With `resume`, continues the file already at `destination` when the server can send the
    /// rest of the same file, and starts over otherwise. On failure or cancellation it leaves
    /// what it wrote; the caller decides whether to keep it.
    /// - Parameters:
    ///   - checkpoint: called once the response arrives, then whenever written bytes have been
    ///     flushed to disk.
    ///   - progress: called only once the size is known, and with the final count on success.
    func download(
        from url: URL,
        to destination: URL,
        resume: ResumePoint?,
        checkpoint: @escaping @Sendable (DownloadCheckpoint) -> Void,
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
        try await download(from: url, to: destination, resume: nil, checkpoint: { _ in }, progress: progress)
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
