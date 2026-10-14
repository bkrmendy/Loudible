import AppKit
import LoudibleCore
import LoudiblePresentation
import SwiftUI

/// The library as a cover grid; account, search, and refresh live in the toolbar.
struct ContentView: View {
    let model: AppViewModel
    @State private var pendingDelete: Audiobook?

    var body: some View {
        @Bindable var library = model.library
        LibraryGridContent(
            books: library.visibleBooks,
            isLibraryEmpty: library.books.isEmpty,
            isSignedIn: library.isSignedIn,
            isLoading: library.isLoading,
            isCheckingMarketplaces: library.isCheckingMarketplaces,
            canSelect: library.canSelect,
            tile: { book in
                BookTileState(
                    isSelected: library.isSelected(book.asin),
                    isInLibrary: library.isInLibrary(book.asin),
                    marketplaceBadge: library.marketplaceBadge(for: book),
                    status: model.status(for: book),
                    menuItems: model.menuItems(for: book)
                )
            },
            toggle: { library.toggleSelection($0.asin) },
            perform: perform,
            clearSelection: { library.clearSelection() }
        )
        .searchable(
            text: $library.searchText, placement: .toolbarPrincipal,
            prompt: "Search title, author, narrator"
        )
        // Signed out there is nothing to search. While re-authenticating the last library stays
        // visible, so search and the grid stay usable then.
        .disabled(isSignedOutAndEmpty)
        .overlay {
            if isSignedOutAndEmpty, model.session.hasRestored {
                SignInPanel(session: model.session)
            }
        }
        .background {
            // Escape deselects. Only while something is selected, so otherwise Escape still
            // reaches the search field.
            if !library.selection.isEmpty {
                Button("Deselect All") { library.clearSelection() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .toolbar { toolbar }
        .bar(edge: .top) {
            MessagesBar(
                messages: [
                    model.session.errorMessage, model.library.errorMessage, model.export.errorMessage,
                ].compactMap { $0 },
                notices: [model.export.notice, model.library.marketplaceNotice].compactMap { $0 }
            )
        }
        .confirmationDialog(
            pendingDeleteIsPartial
                ? "Discard the unfinished download of “\(pendingDelete?.title ?? "")”?"
                : "Move “\(pendingDelete?.title ?? "")” to the Trash?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { book in
            Button(pendingDeleteIsPartial ? "Discard" : "Move to Trash", role: .destructive) {
                Task { await model.deleteDownload(book) }
            }
        } message: { _ in
            Text(pendingDeleteIsPartial ? "The next download starts from the beginning." : "The exported M4B is not affected.")
        }
        .removingToolbarTitle()
        .loginSheet(for: model.session)
    }

    /// Whether the book to delete has only an unfinished download, which is deleted outright.
    private var pendingDeleteIsPartial: Bool {
        guard let book = pendingDelete else { return false }
        return model.downloadedFiles[book.asin] == nil
    }

    private var isSignedOutAndEmpty: Bool {
        !model.session.isSignedIn && model.library.books.isEmpty
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Signed out, the sign-in panel in the window takes its place. While re-authenticating
        // with the last library still shown, it stays: it is the way to sign in again.
        if !isSignedOutAndEmpty {
            ToolbarItem(placement: .navigation) {
                AccountButton(model: model)
            }
        }
        if !model.library.selectedBooks.isEmpty {
            ToolbarItemGroup(placement: .primaryAction) {
                SelectionActions(
                    downloadCount: model.selectedBooks(offering: .download).count,
                    exportCount: model.selectedBooks(offering: .export).count,
                    perform: { action in Task { await model.performOnSelection(action) } }
                )
            }
        }
        ToolbarItem(placement: .primaryAction) {
            let isBusy = model.library.isLoading || model.library.isCheckingMarketplaces
            // While busy the spinner stays inside the button, so it gets the button's round
            // toolbar background instead of a narrow capsule of its own.
            Button {
                Task { await model.refreshLibrary() }
            } label: {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh Library", systemImage: "arrow.clockwise")
                }
            }
            .help(
                model.library.isCheckingMarketplaces && !model.library.isLoading
                    ? "Checking other Audible marketplaces for more titles…" : "Refresh library"
            )
            .disabled(isBusy || !model.library.canRefresh)
        }
    }

    private func perform(_ action: BookAction, on book: Audiobook) {
        switch action {
        case .showDownload:
            if let url = model.downloadedFiles[book.asin] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .showExport:
            if let url = model.exportedFiles[book.asin] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .deleteDownload:
            pendingDelete = book
        case .download, .resumeDownload, .cancel, .export:
            Task { await model.perform(action, on: book) }
        }
    }
}

/// Download and Export for the selected books, in the toolbar while something is selected. Each
/// acts on the selected books whose menu offers it, and is disabled when none does.
struct SelectionActions: View {
    let downloadCount: Int
    let exportCount: Int
    let perform: (BookAction) -> Void

    var body: some View {
        Button("Download", systemImage: "arrow.down.circle") { perform(.download) }
            .help(help(count: downloadCount, action: "Download", none: "downloaded"))
            .disabled(downloadCount == 0)
            .labelStyle(.titleAndIcon)
        Button("Export", systemImage: "square.and.arrow.up") { perform(.export) }
            .help(help(count: exportCount, action: "Export to M4B", none: "exported"))
            .disabled(exportCount == 0)
            .labelStyle(.titleAndIcon)
    }

    private func help(count: Int, action: String, none: String) -> String {
        switch count {
        case 0: "None of the selected books can be \(none)"
        case 1: "\(action) 1 book"
        default: "\(action) \(count) books"
        }
    }
}

private extension View {
    /// Presents the sign-in sheet while a login is pending; closing it cancels the login.
    func loginSheet(for session: SessionViewModel) -> some View {
        sheet(
            isPresented: Binding(
                get: { session.pendingLogin != nil },
                set: { if !$0 { Task { await session.cancelSignIn() } } }
            )
        ) {
            if let login = session.pendingLogin {
                LoginSheet(session: session, login: login)
            }
        }
    }

    /// Hides the window title from the toolbar; macOS 14 keeps it.
    @ViewBuilder
    func removingToolbarTitle() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }

    /// A bar pinned to the edge of a scroll view. macOS 26 gives it the system scroll edge effect;
    /// earlier versions fall back to an inset on the bar material.
    @ViewBuilder
    func bar(edge: VerticalEdge, @ViewBuilder content: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, content: content)
        } else {
            safeAreaInset(edge: edge) { content().background(.bar) }
        }
    }
}

#if DEBUG
#Preview("Window – signed out") { PreviewCatalog.view(.windowSignedOut) }
#Preview("Window – library") { PreviewCatalog.view(.windowLibrary) }
#Preview("Window – selection") { PreviewCatalog.view(.windowSelection) }
#Preview("Window – loading") { PreviewCatalog.view(.windowLoading) }
#Preview("Window – load failed") { PreviewCatalog.view(.windowLoadFailed) }
#endif
