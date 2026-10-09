import AudibleExporterCore
import AudibleExporterPresentation
import SwiftUI

/// What a book's tile shows besides the book itself.
struct BookTileState: Equatable {
    var isSelected = false
    var isInLibrary = true
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
    let canSelect: Bool
    let tile: (Audiobook) -> BookTileState
    let toggle: (Audiobook) -> Void
    let perform: (BookAction, Audiobook) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 18, alignment: .top)
    ]

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
        }
        .overlay {
            if isLibraryEmpty {
                Text(
                    isSignedIn
                        ? (isLoading ? "Loading library…" : "No purchased audiobooks")
                        : "Sign in to see your library"
                )
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Error messages above the grid; nothing when there are none.
struct MessagesBar: View {
    let messages: [String]

    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.red.opacity(0.08))
        }
    }
}

/// A cover with its status badge, then the title row with the actions menu. The cover and the
/// title toggle selection; the dots menu sits outside those buttons so it never does.
struct BookTile: View {
    let book: Audiobook
    let state: BookTileState
    let canSelect: Bool
    let toggle: () -> Void
    let perform: (BookAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                cover
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                state.isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                lineWidth: state.isSelected ? 3 : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if state.isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        BookStatusBadge(status: state.status).padding(6)
                    }
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSelect)
            .help(tooltip)
            .accessibilityLabel(book.title)
            .accessibilityValue(state.status.accessibilityText ?? "")
            .accessibilityAddTraits(state.isSelected ? .isSelected : [])
            .accessibilityActions {
                ForEach(state.menuItems.filter(\.isEnabled)) { item in
                    Button(item.action.title) { perform(item.action) }
                }
            }

            HStack(alignment: .top, spacing: 4) {
                Button(action: toggle) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                        Text(book.authors.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !state.isInLibrary {
                            Text("Not in library").font(.caption2).foregroundStyle(.orange)
                        }
                        if let length = book.runtimeMinutes.map({ "\($0 / 60)h \($0 % 60)m" }) {
                            Text(length).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSelect)
                .help(tooltip)
                // The cover button already is this tile's element for VoiceOver.
                .accessibilityHidden(true)

                Menu {
                    BookMenuContent(items: state.menuItems, perform: perform)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(state.menuItems.isEmpty)
                .help("More actions")
                .accessibilityLabel("More actions for \(book.title)")
            }
        }
        .contextMenu { BookMenuContent(items: state.menuItems, perform: perform) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var cover: some View {
        AsyncImage(url: book.coverImageURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tooltip: String {
        var lines = [book.title]
        if let subtitle = book.subtitle { lines.append(subtitle) }
        if !book.authors.isEmpty { lines.append("By " + book.authors.joined(separator: ", ")) }
        if !book.narrators.isEmpty {
            lines.append("Narrated by " + book.narrators.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

/// The items of a book's dots menu and context menu (one definition for both).
private struct BookMenuContent: View {
    let items: [BookMenuItem]
    let perform: (BookAction) -> Void

    var body: some View {
        ForEach(items) { item in
            Button(item.action.title, role: item.action == .deleteDownload ? .destructive : nil) {
                perform(item.action)
            }
            .disabled(!item.isEnabled)
            if let reason = item.disabledReason {
                // Menus show no tooltips; a disabled line explains the disabled item.
                Text(reason)
            }
        }
    }
}

/// The status icon in the cover's corner, on a dark disc so it reads on any artwork.
private struct BookStatusBadge: View {
    let status: BookStatus

    var body: some View {
        if let content {
            content
                .frame(width: 18, height: 18)
                .padding(4)
                .background(Circle().fill(.black.opacity(0.6)))
                .help(status.accessibilityText ?? "")
                .accessibilityHidden(true)
        }
    }

    private var content: AnyView? {
        switch status {
        case .none:
            nil
        case .queued:
            AnyView(icon("clock", .white))
        case .running(let kind, let progress):
            AnyView(ProgressRing(progress: progress, color: kind == .export ? .accentColor : .white))
        case .failed:
            AnyView(icon("exclamationmark.triangle.fill", .yellow))
        case .downloaded:
            AnyView(icon("arrow.down.circle.fill", .white))
        case .exported:
            AnyView(icon("checkmark.seal.fill", .green))
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
    }
}

private struct ProgressRing: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1)
    }
}

extension BookAction {
    fileprivate var title: String {
        switch self {
        case .download: "Download"
        case .cancel(_, .download): "Cancel Download"
        case .cancel(_, .export): "Cancel Export"
        case .export: "Export to M4B"
        case .showDownload: "Show in Finder"
        case .showExport: "Show Exported File in Finder"
        case .deleteDownload: "Delete Download…"
        }
    }
}

#if DEBUG
#Preview("Tile – unselected") { PreviewCatalog.view(.tileUnselected) }
#Preview("Tile – selected") { PreviewCatalog.view(.tileSelected) }
#Preview("Tile – no cover") { PreviewCatalog.view(.tileNoCover) }
#Preview("Tile – long title, several authors") { PreviewCatalog.view(.tileLongTitle) }
#Preview("Tile – no runtime") { PreviewCatalog.view(.tileNoRuntime) }
#Preview("Tile – disabled") { PreviewCatalog.view(.tileDisabled) }
#Preview("Tile – not in library") { PreviewCatalog.view(.tileNotInLibrary) }
#Preview("Tile – queued") { PreviewCatalog.view(.tileQueued) }
#Preview("Tile – downloading") { PreviewCatalog.view(.tileDownloading) }
#Preview("Tile – exporting") { PreviewCatalog.view(.tileExporting) }
#Preview("Tile – failed") { PreviewCatalog.view(.tileFailed) }
#Preview("Tile – downloaded") { PreviewCatalog.view(.tileDownloaded) }
#Preview("Tile – exported") { PreviewCatalog.view(.tileExported) }
#Preview("Grid – signed out") { PreviewCatalog.view(.gridSignedOut) }
#Preview("Grid – loading") { PreviewCatalog.view(.gridLoading) }
#Preview("Grid – empty library") { PreviewCatalog.view(.gridEmpty) }
#Preview("Grid – books") { PreviewCatalog.view(.gridBooks) }
#Preview("Grid – books with selection") { PreviewCatalog.view(.gridSelection) }
#Preview("Grid – no search results") { PreviewCatalog.view(.gridNoSearchResults) }
#Preview("Messages – none") { PreviewCatalog.view(.messagesNone) }
#Preview("Messages – one") { PreviewCatalog.view(.messagesOne) }
#Preview("Messages – several long") { PreviewCatalog.view(.messagesSeveral) }
#endif
