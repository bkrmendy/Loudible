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
        if entry.relationships
            .contains(where: { $0.direction == .child && containerRelationshipTypes.contains($0.type ?? "") })
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

    /// Title fragments whose books are never shown, matched case- and diacritic-insensitively.
    public static let hiddenTitleFragments = ["Morning"]

    /// Whether the book is left out of the library, remote or downloaded.
    public static func isHidden(_ book: Audiobook) -> Bool {
        hiddenTitleFragments
            .contains { book.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// `existing` followed by the books of `new` whose ASIN it does not have yet, so the home
    /// store's copy of a title wins over another store's.
    public static func merge(_ existing: [Audiobook], _ new: [Audiobook]) -> [Audiobook] {
        var seen = Set(existing.map(\.asin))
        return existing + new.filter { seen.insert($0.asin).inserted }
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
            let fields = [book.title, book.subtitle, book.seriesTitle, book.asin].compactMap { $0 } + book
                .authors + book.narrators
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

/// The outcome of loading one marketplace other than the signed-in one.
public enum MarketplaceScan: Sendable, Equatable {
    /// The store holds purchased titles.
    case titles(Marketplace, [Audiobook])
    /// The store holds nothing that counts as purchased.
    case empty(Marketplace)
    /// The store could not be loaded. Affects that store only, never the session.
    case failed(Marketplace, ExporterError)

    public var marketplace: Marketplace {
        switch self {
        case .titles(let marketplace, _), .empty(let marketplace), .failed(let marketplace, _): marketplace
        }
    }
}

/// Fetches every library page and applies the ownership rules.
///
/// Audible keeps one library per marketplace: a title bought while the Amazon account was set to
/// another country lives only in that country's library. The signed-in (home) store is loaded
/// first; the others can then be checked one by one with the same device registration.
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

    /// The signed-in marketplace and its purchased books.
    public func fetchHomeLibrary() async throws(ExporterError) -> (marketplace: Marketplace, books: [Audiobook]) {
        let home = try await auth.validSession().marketplace
        return (home, try await fetchPurchasedBooks(in: home))
    }

    /// The purchased books in `marketplace`. A rejected token is refreshed and retried, and a
    /// second rejection requires signing in again, so use this for the home store only.
    public func fetchPurchasedBooks(in marketplace: Marketplace) async throws(ExporterError) -> [Audiobook] {
        let api = self.api, auth = self.auth, pageSize = self.pageSize
        return try await fetchPages { number throws(ExporterError) in
            try await auth.withValidSession { session in
                try await api.libraryPage(number, pageSize: pageSize, marketplace: marketplace, session: session)
            }
        }
    }

    /// Loads every marketplace except `home`, one after another in `Marketplace.all` order.
    ///
    /// A store that rejects the request yields `.failed` for that store only: unlike the home
    /// store, a rejection here must never end the session or delete the stored credentials.
    /// Ends early when the consuming task is cancelled.
    public func fetchOtherMarketplaces(excluding home: Marketplace) -> AsyncStream<MarketplaceScan> {
        let (stream, continuation) = AsyncStream<MarketplaceScan>.makeStream()
        let task = Task {
            for marketplace in Marketplace.all where marketplace != home {
                let scan = await scan(marketplace)
                if Task.isCancelled { break }
                continuation.yield(scan)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func scan(_ marketplace: Marketplace) async -> MarketplaceScan {
        let api = self.api, auth = self.auth, pageSize = self.pageSize
        do {
            let books = try await fetchPages { number throws(ExporterError) in
                // Refreshes (shared with any other caller) when the token is about to expire.
                let session = try await auth.validSession()
                do {
                    return try await api.libraryPage(
                        number,
                        pageSize: pageSize,
                        marketplace: marketplace,
                        session: session)
                } catch {
                    throw ExporterError.from(error)
                }
            }
            return books.isEmpty ? .empty(marketplace) : .titles(marketplace, books)
        } catch {
            return .failed(marketplace, error)
        }
    }

    private func fetchPages(
        _ page: (Int) async throws(ExporterError) -> LibraryPage
    ) async throws(ExporterError) -> [Audiobook] {
        var entries: [LibraryEntry] = []
        var seen = Set<String>()
        var received = 0
        for number in 1...Self.maximumPages {
            let page = try await page(number)
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
