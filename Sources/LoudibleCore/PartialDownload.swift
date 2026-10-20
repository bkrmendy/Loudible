import Foundation

/// An unfinished download kept to be continued: after a quit, a crash, a sign-out or a failure.
/// `LocalDownloads` stores it next to the manifests; the bytes are in
/// `LocalDownloads.partialFileURL(for:)`.
public struct PartialDownload: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var book: Audiobook
    /// The account that downloaded it. Another account's license may not decrypt these bytes.
    public var customerID: String
    public var fileExtension: String
    public var checkpoint: DownloadCheckpoint
    public var updatedAt: Date

    public init(
        book: Audiobook,
        customerID: String,
        fileExtension: String,
        checkpoint: DownloadCheckpoint,
        updatedAt: Date) {
        self.version = Self.currentVersion
        self.book = book
        self.customerID = customerID
        self.fileExtension = fileExtension
        self.checkpoint = checkpoint
        self.updatedAt = updatedAt
    }
}
