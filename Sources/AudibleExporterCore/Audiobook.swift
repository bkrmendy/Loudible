import Foundation

/// A purchased audiobook as shown in the library and exported to M4B.
public struct Audiobook: Sendable, Hashable, Identifiable, Codable {
    public var id: String { asin }

    public let asin: String
    public var title: String
    public var subtitle: String?
    public var authors: [String]
    public var narrators: [String]
    public var seriesTitle: String?
    public var publisher: String?
    public var runtimeMinutes: Int?
    /// Release date as returned by Audible (`yyyy-MM-dd`).
    public var releaseDate: String?
    public var purchaseDate: Date?
    public var coverImageURL: URL?

    public init(
        asin: String,
        title: String,
        subtitle: String? = nil,
        authors: [String] = [],
        narrators: [String] = [],
        seriesTitle: String? = nil,
        publisher: String? = nil,
        runtimeMinutes: Int? = nil,
        releaseDate: String? = nil,
        purchaseDate: Date? = nil,
        coverImageURL: URL? = nil
    ) {
        self.asin = asin
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.narrators = narrators
        self.seriesTitle = seriesTitle
        self.publisher = publisher
        self.runtimeMinutes = runtimeMinutes
        self.releaseDate = releaseDate
        self.purchaseDate = purchaseDate
        self.coverImageURL = coverImageURL
    }
}

/// A product relationship from the library response, e.g. an episode's parent podcast.
public struct ProductRelationship: Sendable, Hashable {
    public enum Direction: String, Sendable {
        /// The related product is this item's parent.
        case parent
        /// The related product is this item's child.
        case child
    }

    public let asin: String?
    public let direction: Direction?
    /// Audible relationship type, lowercased: `episode`, `season`, `series`, `component`, ...
    public let type: String?

    public init(asin: String?, direction: Direction?, type: String?) {
        self.asin = asin
        self.direction = direction
        self.type = type?.lowercased()
    }
}

/// One item of a library page, before ownership filtering.
public struct LibraryEntry: Sendable, Hashable {
    public var book: Audiobook
    /// `SinglePartBook`, `MultiPartBook`, `PodcastParent`, `PodcastEpisode`, ...
    public var contentDeliveryType: String?
    /// `Product`, `Podcast`, `Performance`, ...
    public var contentType: String?
    /// True for titles available through an Audible Plus ("all you can eat") membership.
    public var isAYCE: Bool?
    public var relationships: [ProductRelationship]

    public init(
        book: Audiobook,
        contentDeliveryType: String? = nil,
        contentType: String? = nil,
        isAYCE: Bool? = nil,
        relationships: [ProductRelationship] = []
    ) {
        self.book = book
        self.contentDeliveryType = contentDeliveryType
        self.contentType = contentType
        self.isAYCE = isAYCE
        self.relationships = relationships
    }
}

public struct LibraryPage: Sendable, Equatable {
    public var entries: [LibraryEntry]
    /// Total library size if the server reported it.
    public var totalCount: Int?

    public init(entries: [LibraryEntry], totalCount: Int? = nil) {
        self.entries = entries
        self.totalCount = totalCount
    }
}
