import Foundation
import Observation
import AudibleExporterCore

/// The purchased library with search and multi-selection. Downloaded books that are no longer
/// in the library (returned, expired, filtered out) are appended from their stored details.
@MainActor
@Observable
public final class LibraryViewModel {
    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The library followed by downloaded books that are not in it.
    public private(set) var books: [Audiobook] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var selection = LibrarySelection()
    public var searchText = ""
    /// Maintained by the owner; refresh and selection need a signed-in account.
    public var isSignedIn = false {
        didSet { rebuildBooks() }
    }

    /// Books from the last successful refresh.
    private var remoteBooks: [Audiobook] = []
    private var remoteASINs: Set<String> = []
    /// Downloaded books, from their manifests.
    private var localBooks: [Audiobook] = []

    private let service: LibraryService

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
    public var canRefresh: Bool { isSignedIn && !isLoading }
    public var canSelect: Bool { isSignedIn && !books.isEmpty }
    public var summary: String {
        let visible = visibleBooks.count
        let base = visible == books.count ? "\(books.count) books" : "\(visible) of \(books.count) books"
        return selection.isEmpty ? base : "\(base), \(selection.count) selected"
    }

    // MARK: Actions

    /// Reloads the library. On failure the previous rows stay visible alongside the error.
    public func refresh() async {
        guard canRefresh else { return }
        loadState = .loading
        do {
            remoteBooks = try await service.fetchPurchasedBooks()
            remoteASINs = Set(remoteBooks.map(\.asin))
            rebuildBooks()
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
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
        selection.reconcile(with: merged)
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
        remoteBooks = []
        remoteASINs = []
        localBooks = []
        books = []
        selection.clear()
        searchText = ""
        loadState = .idle
    }
}
