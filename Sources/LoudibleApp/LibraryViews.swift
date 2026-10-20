import AppKit
import LoudibleCore
import LoudiblePresentation
import SwiftUI

/// What a book's tile shows besides the book itself.
struct BookTileState: Equatable {
    var isSelected = false
    var isInLibrary = true
    /// Short code of the store holding the book, when it is not the signed-in one.
    var marketplaceBadge: String?
    var status: BookStatus = .none
    var menuItems: [BookMenuItem] = []
}

/// The cover grid, or a placeholder while the library is empty. Tiles are built lazily from
/// `tile`, so only the visible ones are computed.
struct LibraryGridContent: View {
    /// The books matching the search.
    let books: [Audiobook]
    /// Whether the whole library is empty, as opposed to no book matching the search.
    let isLibraryEmpty: Bool
    let isSignedIn: Bool
    let isLoading: Bool
    var isCheckingMarketplaces = false
    let canSelect: Bool
    let tile: (Audiobook) -> BookTileState
    let toggle: (Audiobook) -> Void
    let perform: (BookAction, Audiobook) -> Void
    /// Called for a click on the background, between or below the tiles.
    var clearSelection: () -> Void = {}

    private let columns = [
        GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 18, alignment: .top)
    ]

    init(
        books: [Audiobook],
        isLibraryEmpty: Bool? = nil,
        isSignedIn: Bool = true,
        isLoading: Bool = false,
        isCheckingMarketplaces: Bool = false,
        canSelect: Bool? = nil,
        tile: @escaping (Audiobook) -> BookTileState = { _ in BookTileState() },
        toggle: @escaping (Audiobook) -> Void = { _ in },
        perform: @escaping (BookAction, Audiobook) -> Void = { _, _ in },
        clearSelection: @escaping () -> Void = {}
    ) {
        self.books = books
        self.isLibraryEmpty = isLibraryEmpty ?? books.isEmpty
        self.isSignedIn = isSignedIn
        self.isLoading = isLoading
        self.isCheckingMarketplaces = isCheckingMarketplaces
        self.canSelect = canSelect ?? (isSignedIn && !books.isEmpty)
        self.tile = tile
        self.toggle = toggle
        self.perform = perform
        self.clearSelection = clearSelection
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(books) { book in
                    BookTile(
                        book: book,
                        state: tile(book),
                        canSelect: canSelect,
                        toggle: { toggle(book) },
                        perform: { perform($0, book) }
                    )
                }
            }
            .padding(20)
            .background { backgroundClickTarget }
        }
        // The grid only covers its rows; this takes clicks in the empty space below them.
        .background { backgroundClickTarget }
        .overlay {
            if isLibraryEmpty, let placeholder {
                Text(placeholder).foregroundStyle(.secondary)
            }
        }
    }

    private var backgroundClickTarget: some View {
        Color.clear.contentShape(Rectangle()).onTapGesture(perform: clearSelection)
    }

    /// Nothing while signed out: the window shows its sign-in prompt there instead.
    private var placeholder: String? {
        guard isSignedIn else { return nil }
        if isLoading { return "Loading library…" }
        return isCheckingMarketplaces ? "Checking other marketplaces…" : "No purchased audiobooks"
    }
}

/// Error messages above the grid, then notices (informational, not failures); nothing when
/// there are neither.
struct MessagesBar: View {
    let messages: [String]
    var notices: [String] = []

    var body: some View {
        if !messages.isEmpty || !notices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                ForEach(notices, id: \.self) { notice in
                    Label(notice, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(messages.isEmpty ? Color.secondary.opacity(0.08) : Color.red.opacity(0.08))
        }
    }
}

#if DEBUG
extension ViewPreviews {
    static var library: [ViewPreview] {
        [
            ViewPreview("gridSignedOut", "Grid – signed out", width: 900, height: 560) {
                LibraryGridContent(books: [], isSignedIn: false)
            },
            ViewPreview("gridLoading", "Grid – loading", width: 900, height: 560) {
                LibraryGridContent(books: [], isLoading: true)
            },
            ViewPreview("gridCheckingMarketplaces", "Grid – checking marketplaces", width: 900, height: 560) {
                LibraryGridContent(books: [], isCheckingMarketplaces: true)
            },
            ViewPreview("gridEmpty", "Grid – empty library", width: 900, height: 560) {
                LibraryGridContent(books: [])
            },
            ViewPreview("gridBooks", "Grid – books", width: 900, height: 560) {
                LibraryGridContent(books: PreviewData.books, tile: { book in
                    BookTileState(
                        isSelected: false,
                        marketplaceBadge: book.marketplace == PreviewData.session.marketplace ? nil : book.marketplace
                        .id
                        .uppercased(),
                        menuItems: [BookMenuItem(.download)])
                })
            },
            ViewPreview("gridSelection", "Grid – books with selection", width: 900, height: 560) {
                LibraryGridContent(books: PreviewData.books, tile: { book in
                    BookTileState(
                        isSelected: [PreviewData.books[1].asin, PreviewData.books[3].asin, PreviewData.books[6].asin]
                            .contains(book.asin),
                        marketplaceBadge: book.marketplace == PreviewData.session.marketplace ? nil : book.marketplace
                        .id
                        .uppercased(),
                        menuItems: [BookMenuItem(.download)])
                })
            },
            ViewPreview("gridNoSearchResults", "Grid – no search results", width: 900, height: 560) {
                LibraryGridContent(books: [], isLibraryEmpty: false)
            },
            ViewPreview("messagesNone", "Messages – none", width: 700, height: 110) {
                MessagesBar(messages: [])
            },
            ViewPreview("messagesOne", "Messages – one", width: 700, height: 110) {
                MessagesBar(messages: ["Could not reach Audible: The Internet connection appears to be offline."])
            },
            ViewPreview("messagesSeveral", "Messages – several long", width: 700, height: 110) {
                MessagesBar(messages: [
                    "Your session expired. Sign in again to continue.",
                    """
                    Audible returned HTTP 503 (Service Unavailable) while loading page 3 of your library. \
                    Try refreshing \
                    in a few minutes.
                    """,
                    "The download folder could not be created or is not writable: /Users/jane/Documents/Loudible",
                ])
            },
            ViewPreview("messagesNotice", "Messages – notice", width: 700, height: 110) {
                MessagesBar(
                    messages: [],
                    notices: ["Couldn’t check the Audible Japan, India marketplaces for more titles."])
            },
        ]
    }
}
#endif
