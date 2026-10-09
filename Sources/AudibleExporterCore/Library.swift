import Foundation

/// Which library items count as purchased audiobooks. Mirrors Libation's default import
/// filters: Audible Plus catalog titles, podcasts, and series/podcast containers are excluded.
public enum LibraryRules {
    public enum Exclusion: Sendable, Equatable {
        case plusCatalog
        case podcast
        case container
    }

    private static let podcastDeliveryTypes: Set<String> = ["podcastparent", "podcastseason", "podcastepisode"]
    private static let containerRelationshipTypes: Set<String> = ["episode", "season", "series"]

    public static func exclusion(for entry: LibraryEntry) -> Exclusion? {
        let deliveryType = entry.contentDeliveryType?.lowercased()
        // A parent of episodes/seasons is a container, not a listenable title.
        if entry.relationships.contains(where: { $0.direction == .child && containerRelationshipTypes.contains($0.type ?? "") })
            || deliveryType == "podcastparent" || deliveryType == "podcastseason" {
            return .container
        }
        if podcastDeliveryTypes.contains(deliveryType ?? "")
            || entry.contentType?.lowercased() == "podcast"
            || entry.relationships.contains(where: { $0.direction == .parent && $0.type == "episode" }) {
            return .podcast
        }
        if entry.isAYCE == true {
            return .plusCatalog
        }
        return nil
    }

    /// Owned audiobooks in library order, without duplicate ASINs (first occurrence wins).
    public static func purchasedBooks(from entries: [LibraryEntry]) -> [Audiobook] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard exclusion(for: entry) == nil, seen.insert(entry.book.asin).inserted else { return nil }
            return entry.book
        }
    }
}

/// Case- and diacritic-insensitive search. Every whitespace-separated term must match
/// the title, subtitle, an author, a narrator, the series, or the ASIN.
public enum LibrarySearch {
    public static func filter(_ books: [Audiobook], query: String) -> [Audiobook] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return books }
        return books.filter { book in
            let fields = [book.title, book.subtitle, book.seriesTitle, book.asin].compactMap { $0 } + book.authors + book.narrators
            return terms.allSatisfy { term in
                fields.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
    }
}

/// The set of selected ASINs.
public struct LibrarySelection: Sendable, Equatable {
    public private(set) var asins: Set<String> = []

    public init(_ asins: Set<String> = []) {
        self.asins = asins
    }

    public var isEmpty: Bool { asins.isEmpty }
    public var count: Int { asins.count }

    public func contains(_ asin: String) -> Bool { asins.contains(asin) }

    public mutating func toggle(_ asin: String) {
        if asins.remove(asin) == nil { asins.insert(asin) }
    }

    public mutating func set(_ asin: String, selected: Bool) {
        if selected { asins.insert(asin) } else { asins.remove(asin) }
    }

    public mutating func select(_ books: [Audiobook]) {
        asins.formUnion(books.map(\.asin))
    }

    public mutating func deselect(_ books: [Audiobook]) {
        asins.subtract(books.map(\.asin))
    }

    public mutating func clear() {
        asins.removeAll()
    }

    /// Drops selected ASINs that are no longer in the library.
    public mutating func reconcile(with books: [Audiobook]) {
        asins.formIntersection(books.map(\.asin))
    }

    /// Selected books in library order.
    public func selectedBooks(in books: [Audiobook]) -> [Audiobook] {
        books.filter { asins.contains($0.asin) }
    }
}

/// Fetches every library page and applies the ownership rules.
public struct LibraryService: Sendable {
    public static let defaultPageSize = 1000
    /// Hard stop in case a server keeps returning full pages.
    static let maximumPages = 1000

    private let api: any AudibleAPI
    private let auth: AuthenticationCoordinator
    private let pageSize: Int

    public init(api: any AudibleAPI, auth: AuthenticationCoordinator, pageSize: Int = LibraryService.defaultPageSize) {
        self.api = api
        self.auth = auth
        self.pageSize = pageSize
    }

    public func fetchPurchasedBooks() async throws(ExporterError) -> [Audiobook] {
        var entries: [LibraryEntry] = []
        var seen = Set<String>()
        var received = 0
        for number in 1...Self.maximumPages {
            let api = self.api, pageSize = self.pageSize
            let page = try await auth.withValidSession { session in
                try await api.libraryPage(number, pageSize: pageSize, session: session)
            }
            received += page.entries.count
            let new = page.entries.filter { seen.insert($0.book.asin).inserted }
            entries += new

            let isLastPage = page.entries.count < pageSize
                || page.totalCount.map { received >= $0 } == true
                // A page with nothing new means the server is repeating itself.
                || new.isEmpty
            if isLastPage { break }
        }
        return LibraryRules.purchasedBooks(from: entries)
    }
}
