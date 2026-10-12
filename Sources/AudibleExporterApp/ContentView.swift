import AppKit
import AudibleExporterCore
import AudibleExporterPresentation
import SwiftUI

/// The library as a cover grid; account, search, refresh, and export live in the toolbar.
struct ContentView: View {
    let model: AppViewModel
    @State private var isShowingProgress = false
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
            perform: perform
        )
        .searchable(
            text: $library.searchText, placement: .toolbarPrincipal,
            prompt: "Search title, author, narrator"
        )
        .toolbar { toolbar }
        .bar(edge: .top) {
            MessagesBar(
                messages: [
                    model.session.errorMessage, model.library.errorMessage, model.export.errorMessage,
                ].compactMap { $0 },
                notices: [model.library.marketplaceNotice].compactMap { $0 }
            )
        }
        .confirmationDialog(
            "Move “\(pendingDelete?.title ?? "")” to the Trash?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { book in
            Button("Move to Trash", role: .destructive) {
                Task { await model.deleteDownload(book) }
            }
        } message: { _ in
            Text("The exported M4B is not affected.")
        }
        .removingToolbarTitle()
        // While the progress sheet is up, the sign-in sheet is presented on top of it instead.
        .loginSheet(for: model.session, isEnabled: !isShowingProgress)
        .sheet(isPresented: $isShowingProgress) {
            ExportProgressSheet(model: model) { isShowingProgress = false }
                .loginSheet(for: model.session, isEnabled: true)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            AccountButton(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            if model.library.isLoading {
                ProgressView().controlSize(.small)
            } else if model.library.isCheckingMarketplaces {
                ProgressView().controlSize(.small)
                    .help("Checking other Audible marketplaces for more titles…")
            } else {
                Button("Refresh Library", systemImage: "arrow.clockwise") {
                    Task { await model.refreshLibrary() }
                }
                .help("Refresh library")
                .disabled(!model.library.canRefresh)
            }
        }
        // The export button draws its own capsule, so it opts out of the toolbar's shared glass
        // background; the fixed spacer keeps it apart from Refresh.
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { exportButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { exportButton }
        }
    }

    private var exportButton: some View {
        ExportButton(model: model) { isShowingProgress = true }
    }

    private func perform(_ action: BookAction, on book: Audiobook) {
        switch action {
        case .showDownload:
            if let url = model.downloadedFiles[book.asin] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .showExport:
            if let url = model.exportedFiles[book.asin] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .deleteDownload:
            pendingDelete = book
        case .download, .cancel, .export:
            Task { await model.perform(action, on: book) }
        }
    }
}

private extension View {
    /// Presents the sign-in sheet while a login is pending; closing it cancels the login.
    func loginSheet(for session: SessionViewModel, isEnabled: Bool) -> some View {
        sheet(
            isPresented: Binding(
                get: { isEnabled && session.pendingLogin != nil },
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
#Preview("Window – loading") { PreviewCatalog.view(.windowLoading) }
#Preview("Window – load failed") { PreviewCatalog.view(.windowLoadFailed) }
#endif
