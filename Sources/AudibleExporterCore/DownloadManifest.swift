import Foundation

/// What is kept next to each download so it can be exported without contacting Audible, and
/// shown after it has left the library. It contains key material: `LocalDownloads` stores it
/// outside the user-visible download folder, readable by the owner only.
public struct DownloadManifest: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var book: Audiobook
    public var decryption: ContentLicense.Decryption
    public var chapters: [Chapter]
    public var fileExtension: String
    public var downloadedAt: Date

    public init(book: Audiobook, decryption: ContentLicense.Decryption, chapters: [Chapter], downloadedAt: Date) {
        self.version = Self.currentVersion
        self.book = book
        self.decryption = decryption
        self.chapters = chapters
        self.fileExtension = decryption.fileExtension
        self.downloadedAt = downloadedAt
    }
}
