import Foundation
import Observation
import LoudibleCore

/// The purchased library with search and multi-selection. Downloaded books that are no longer
/// in the library (returned, expired, filtered out) are appended from their stored details.
///
/// A refresh loads the signed-in marketplace first and shows it, then checks every other
/// marketplace and merges the titles found there.
@MainActor
@Observable
public final class LibraryViewModel {
    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// A marketplace other than the signed-in one that holds titles.
    public struct MarketplaceCount: Equatable, Sendable {
        public let marketplace: Marketplace
        /// Titles shown from this store (not counting ones the home store also has).
        public let count: Int

        public init(marketplace: Marketplace, count: Int) {
            self.marketplace = marketplace
            self.count = count
        }
    }

    /// The library followed by downloaded books that are not in it.
    public private(set) var books: [Audiobook] = []
    public private(set) var loadState: LoadState = .idle
    /// True while the other marketplaces are being checked, after the home library loaded.
    public private(set) var isCheckingMarketplaces = false
    /// The signed-in marketplace of the last successful refresh.
    public private(set) var homeMarketplace: Marketplace?
    /// Other marketplaces with titles in the library, in `Marketplace.all` order.
    public private(set) var otherMarketplaces: [MarketplaceCount] = []
    /// Marketplaces the last check could not load. Their earlier titles, if any, stay listed.
    public private(set) var uncheckedMarketplaces: [Marketplace] = []
    public private(set) var selection = LibrarySelection()
    public var searchText = ""
    /// Maintained by the owner; refresh and selection need a signed-in account.
    public var isSignedIn = false {
        didSet { rebuildBooks() }
    }

    /// Books from the home marketplace's last successful load.
    private var homeBooks: [Audiobook] = []
    /// Books from other marketplaces, kept per store until that store answers again.
    private var foreignBooks: [Marketplace: [Audiobook]] = [:]
    /// The home books followed by the other stores' titles.
    private var remoteBooks: [Audiobook] = []
    private var remoteASINs: Set<String> = []
    /// Downloaded books, from their manifests.
    private var localBooks: [Audiobook] = []

    private let service: LibraryService
    @ObservationIgnored private var marketplaceTask: Task<Void, Never>?
    /// Changes with every refresh and reset, so a late answer can tell it is stale.
    @ObservationIgnored private var generation = 0

    public init(service: LibraryService) {
        self.service = service
    }

    // MARK: Derived state

    public var isLoading: Bool { loadState == .loading }
    public var errorMessage: String? {
        if case .failed(let message) = loadState { message } else { nil }
    }
    public var visibleBooks: [Audiobook] { LibrarySearch.filter(books, query: searchText) }
    public var selectedBooks: [Audiobook] { selection.selectedBooks(in: books) }
    public var canRefresh: Bool { isSignedIn && !isLoading && !isCheckingMarketplaces }
    public var canSelect: Bool { isSignedIn && !books.isEmpty }
    public var summary: String {
        let visible = visibleBooks.count
        var base = visible == books.count ? "\(books.count) books" : "\(visible) of \(books.count) books"
        if !otherMarketplaces.isEmpty {
            base += " · also in " + otherMarketplaces.map(\.marketplace.name).joined(separator: ", ")
        }
        return selection.isEmpty ? base : "\(base), \(selection.count) selected"
    }
    /// Not an error: the library is complete apart from these stores.
    public var marketplaceNotice: String? {
        guard !uncheckedMarketplaces.isEmpty else { return nil }
        return "Couldn’t check the Audible \(uncheckedMarketplaces.map(\.name).joined(separator: ", ")) "
            + (uncheckedMarketplaces.count == 1 ? "marketplace" : "marketplaces") + " for more titles."
    }

    /// A short store label for books from a marketplace other than the signed-in one.
    public func marketplaceBadge(for book: Audiobook) -> String? {
        guard let homeMarketplace, book.marketplace != homeMarketplace else { return nil }
        return book.marketplace.id.uppercased()
    }

    // MARK: Actions

    /// Reloads the library: the home marketplace, then the others. If the home store fails, the
    /// previous rows stay visible alongside the error and the others are not checked.
    public func refresh() async {
        guard isSignedIn, !isLoading else { return }
        marketplaceTask?.cancel()
        marketplaceTask = nil
        isCheckingMarketplaces = false
        loadState = .loading
        generation += 1
        let current = generation
        let result: Result<(marketplace: Marketplace, books: [Audiobook]), ExporterError>
        do {
            result = .success(try await service.fetchHomeLibrary())
        } catch {
            result = .failure(error)
        }
        // Reset (signed out) meanwhile: the answer belongs to the old account.
        guard generation == current else { return }
        let home: Marketplace
        switch result {
        case .success(let library):
            (home, homeBooks) = library
        case .failure(let error):
            loadState = .failed(error.localizedDescription)
            return
        }
        homeMarketplace = home
        foreignBooks[home] = nil
        // Selected titles from other stores are still to come: reconcile once they are in.
        isCheckingMarketplaces = true
        rebuildRemote()
        loadState = .loaded

        let task = Task { await checkOtherMarketplaces(excluding: home) }
        marketplaceTask = task
        await task.value
    }

    private func checkOtherMarketplaces(excluding home: Marketplace) async {
        var unchecked: [Marketplace] = []
        for await scan in service.fetchOtherMarketplaces(excluding: home) {
            guard !Task.isCancelled else { break }
            switch scan {
            case .titles(let marketplace, let books):
                foreignBooks[marketplace] = books
            case .empty(let marketplace):
                foreignBooks[marketplace] = nil
            case .failed(let marketplace, _):
                unchecked.append(marketplace)
            }
            rebuildRemote()
        }
        // A cancelled check belongs to a reset or a newer refresh, which owns the state now.
        guard !Task.isCancelled else { return }
        uncheckedMarketplaces = unchecked
        isCheckingMarketplaces = false
        marketplaceTask = nil
        selection.reconcile(with: books)
    }

    private func rebuildRemote() {
        var merged = homeBooks
        var counts: [MarketplaceCount] = []
        for marketplace in Marketplace.all where marketplace != homeMarketplace {
            guard let books = foreignBooks[marketplace] else { continue }
            let before = merged.count
            merged = LibraryRules.merge(merged, books)
            if merged.count > before { counts.append(MarketplaceCount(marketplace: marketplace, count: merged.count - before)) }
        }
        remoteBooks = merged
        remoteASINs = Set(merged.map(\.asin))
        if counts != otherMarketplaces { otherMarketplaces = counts }
        rebuildBooks()
    }

    /// Whether the book was in the last refreshed library (false for downloaded books that left it).
    public func isInLibrary(_ asin: String) -> Bool { remoteASINs.contains(asin) }

    /// Replaces the downloaded books shown alongside the library.
    public func applyLocal(_ books: [Audiobook]) {
        guard books != localBooks else { return }
        localBooks = books
        rebuildBooks()
    }

    /// Signed out, the grid stays empty; while re-authenticating the last library stays visible.
    private func rebuildBooks() {
        let showsLocal = isSignedIn || !remoteBooks.isEmpty
        let extra = showsLocal ? localBooks.filter { !remoteASINs.contains($0.asin) } : []
        let merged = remoteBooks + extra.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        guard merged != books else { return }
        books = merged
        if !isCheckingMarketplaces { selection.reconcile(with: merged) }
    }

    public func isSelected(_ asin: String) -> Bool { selection.contains(asin) }

    public func toggleSelection(_ asin: String) {
        guard canSelect, books.contains(where: { $0.asin == asin }) else { return }
        selection.toggle(asin)
    }

    /// Replaces the selection, e.g. from a table's selection binding. Unknown ASINs are ignored.
    public func setSelection(_ asins: Set<String>) {
        guard canSelect else { return }
        selection = LibrarySelection(asins)
        selection.reconcile(with: books)
    }

    public func selectAllVisible() {
        guard canSelect else { return }
        selection.select(visibleBooks)
    }

    public func deselectAllVisible() {
        selection.deselect(visibleBooks)
    }

    public func clearSelection() {
        selection.clear()
    }

    /// Forgets the library, e.g. after signing out.
    public func reset() {
        generation += 1
        marketplaceTask?.cancel()
        marketplaceTask = nil
        isCheckingMarketplaces = false
        homeMarketplace = nil
        homeBooks = []
        foreignBooks = [:]
        otherMarketplaces = []
        uncheckedMarketplaces = []
        remoteBooks = []
        remoteASINs = []
        localBooks = []
        books = []
        selection.clear()
        searchText = ""
        loadState = .idle
    }
}
