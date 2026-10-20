import AppKit
import LoudibleCore
import SwiftUI

/// A cover with its status badge, then the title row with the actions menu. The cover and the
/// title toggle selection; the dots menu sits outside those buttons so it never does.
struct BookTile: View {
    let book: Audiobook
    var state = BookTileState()
    var canSelect = true
    var toggle: () -> Void = {}
    var perform: (BookAction) -> Void = { _ in }

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
                    .overlay(alignment: .topLeading) {
                        if let badge = state.marketplaceBadge {
                            MarketplaceBadge(code: badge).padding(6)
                        }
                    }
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSelect)
            .help(tooltip)
            .accessibilityLabel(book.title)
            .accessibilityValue(
                [state.marketplaceBadge.map { "Audible \($0)" }, state.status.accessibilityText].compactMap { $0 }
                    .joined(separator: ", "))
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
                        // Takes the runtime's place while downloading, so the tile keeps its height.
                        if let transferred = state.status.transferred {
                            Text(transferred.text).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        } else if let length = book.runtimeMinutes.map({ "\($0 / 60)h \($0 % 60)m" }) {
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
                    Image(nsImage: .verticalEllipsis)
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

/// The store code in the cover's corner, e.g. "UK", for titles from another marketplace.
private struct MarketplaceBadge: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.6)))
            .help("From the Audible \(code) marketplace")
            .accessibilityHidden(true)
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
        case .none, .failed, .exported:
            nil
        case .queued:
            AnyView(icon("clock", .white))
        case .paused:
            AnyView(icon("pause.circle.fill", .white))
        case .running(let kind, let progress, _):
            AnyView(ProgressRing(progress: progress, color: kind == .export ? .accentColor : .white))
        case .downloaded:
            AnyView(icon("arrow.down.circle.fill", .white))
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

extension NSImage {
    /// SF Symbols has no plain vertical ellipsis, and a menu's label ignores `rotationEffect`, so
    /// this is the horizontal one turned upright, as a template image so it takes the menu's tint.
    fileprivate static let verticalEllipsis: NSImage = {
        let symbol = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(textStyle: .body, scale: .large))!
        let size = NSSize(width: symbol.size.height, height: symbol.size.width)
        let image = NSImage(size: size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: 90)
            transform.concat()
            symbol.draw(in: NSRect(x: -symbol.size.width / 2, y: -symbol.size.height / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "More actions"
        return image
    }()
}

extension BookStatus {
    /// The download bytes to show instead of the runtime: received so far, or kept for later.
    fileprivate var transferred: TransferProgress? {
        switch self {
        case .running(_, _, let transferred): transferred
        case .failed(_, _, let kept): kept
        case .paused(let kept): kept
        case .none, .queued, .downloaded, .exported: nil
        }
    }
}

extension BookAction {
    fileprivate var title: String {
        switch self {
        case .download: "Download"
        case .resumeDownload: "Resume Download"
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
extension ViewPreviews {
    static var bookTile: [ViewPreview] {
        [
            ViewPreview("tileUnselected", "Tile – unselected", width: 200, height: 280) {
                BookTile(book: PreviewData.books[0])
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileSelected", "Tile – selected", width: 200, height: 280) {
                BookTile(book: PreviewData.books[0], state: BookTileState(isSelected: true))
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileNoCover", "Tile – no cover", width: 200, height: 280) {
                BookTile(book: PreviewData.books[2])
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileLongTitle", "Tile – long title, several authors", width: 200, height: 280) {
                BookTile(book: PreviewData.books[4])
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileNoRuntime", "Tile – no runtime", width: 200, height: 280) {
                BookTile(book: PreviewData.books[7])
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileDisabled", "Tile – disabled", width: 200, height: 280) {
                BookTile(book: PreviewData.books[0], canSelect: false)
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileNotInLibrary", "Tile – not in library", width: 200, height: 280) {
                BookTile(book: PreviewData.books[1],
                    state: PreviewData.tileState(isInLibrary: false, status: .downloaded))
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileOtherMarketplace", "Tile – other marketplace", width: 200, height: 280) {
                BookTile(book: PreviewData.books[3], state: BookTileState(marketplaceBadge: "UK", status: .downloaded))
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileQueued", "Tile – queued", width: 200, height: 280) {
                BookTile(book: PreviewData.books[1], state: PreviewData.tileState(status: .queued(.download)))
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileDownloading", "Tile – downloading", width: 200, height: 280) {
                BookTile(book: PreviewData.books[1], state: PreviewData.tileState(status: .running(
                    .download,
                    progress: 0.4,
                    transferred: TransferProgress(bytesReceived: 132_000_000, bytesExpected: 288_000_000))))
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileExporting", "Tile – exporting", width: 200, height: 280) {
                BookTile(book: PreviewData.books[1],
                    state: PreviewData.tileState(status: .running(.export, progress: 0.7)))
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileFailed", "Tile – failed", width: 200, height: 280) {
                BookTile(book: PreviewData.books[1],
                    state: PreviewData.tileState(status: .failed(.download, "HTTP 403: Forbidden")))
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileFailedPartial", "Tile – failed, part downloaded", width: 200, height: 280) {
                BookTile(book: PreviewData.books[1], state: PreviewData.tileState(status: .failed(
                    .download,
                    "The network connection was lost.",
                    kept: PreviewData.kept)))
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tilePaused", "Tile – download paused", width: 200, height: 280) {
                BookTile(book: PreviewData.books[1], state: PreviewData.tileState(status: .paused(PreviewData.kept)))
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileDownloaded", "Tile – downloaded", width: 200, height: 280) {
                BookTile(book: PreviewData.books[1], state: PreviewData.tileState(status: .downloaded))
                    .frame(width: 150)
                    .padding()
            },
            ViewPreview("tileExported", "Tile – exported", width: 200, height: 280) {
                BookTile(book: PreviewData.books[1], state: PreviewData.tileState(status: .exported))
                    .frame(width: 150)
                    .padding()
            },
        ]
    }
}
#endif
