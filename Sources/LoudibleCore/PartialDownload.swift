import Foundation

/// An unfinished download to resume when possible, or restart with a fresh license.
/// Native temporary files are owned by URLSession, not by `LocalDownloads`.
public struct PartialDownload: Sendable, Equatable, Codable {
    public static let currentVersion = 2

    public var version: Int
    public var book: Audiobook
    /// The account that downloaded it. Another account's license may not decrypt these bytes.
    public var customerID: String
    public var fileExtension: String
    public var recovery: DownloadRecovery
    public var decryption: ContentLicense.Decryption
    public var updatedAt: Date

    public init(
        book: Audiobook,
        customerID: String,
        fileExtension: String,
        recovery: DownloadRecovery,
        decryption: ContentLicense.Decryption,
        updatedAt: Date) {
        self.version = Self.currentVersion
        self.book = book
        self.customerID = customerID
        self.fileExtension = fileExtension
        self.recovery = recovery
        self.decryption = decryption
        self.updatedAt = updatedAt
    }
}
