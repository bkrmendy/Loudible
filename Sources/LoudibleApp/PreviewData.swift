#if DEBUG
import AppKit
import LoudibleCore
import LoudiblePresentation
import SwiftUI

// Synthetic data and in-memory fakes for `#Preview`s and the snapshot tests. Nothing here
// contacts Audible: logins point at `.invalid` hosts and the API never touches the network.

/// Every view state worth looking at. Each `#Preview` shows one, and the snapshot test
/// (`Tests/TestSupport/Snapshot.swift`) renders them all.
enum PreviewState: String, CaseIterable, Sendable {
    // AccountViews.swift
    case avatarInitial, avatarNoName, avatarLarge
    case accountButtonSignedOut, accountButtonSignedIn, accountButtonLongName, accountButtonNeedsReauthentication
    case accountPopoverSignedOut, accountPopoverWorking, accountPopoverExpired, accountPopoverSignedIn,
         accountPopoverOtherMarketplaces
    case signInPanel, signInPanelExpired
    // LibraryViews.swift
    case tileUnselected, tileSelected, tileNoCover, tileLongTitle, tileNoRuntime, tileDisabled, tileNotInLibrary,
         tileOtherMarketplace
    case tileQueued, tileDownloading, tileExporting, tileFailed, tileFailedPartial, tilePaused, tileDownloaded,
         tileExported
    case gridSignedOut, gridLoading, gridCheckingMarketplaces, gridEmpty, gridBooks, gridSelection, gridNoSearchResults
    case messagesNone, messagesOne, messagesSeveral, messagesNotice
    // LoginSheet.swift
    case loginIdle, loginRegistering, loginError, loginPastedURL
    // ContentView.swift
    case windowSignedOut, windowLibrary, windowSelection, windowLoading, windowLoadFailed
}

/// The view and size of each `PreviewState`.
@MainActor
enum PreviewCatalog {
    /// The main window's size in the snapshots.
    static let windowSize = CGSize(width: 1100, height: 600)

    static func size(_ state: PreviewState) -> CGSize {
        switch state {
        case .avatarInitial, .avatarNoName, .avatarLarge: CGSize(width: 80, height: 80)
        case .accountButtonSignedOut, .accountButtonSignedIn, .accountButtonLongName,
            .accountButtonNeedsReauthentication:
            CGSize(width: 260, height: 60)
        case .accountPopoverSignedOut, .accountPopoverWorking, .accountPopoverExpired, .accountPopoverSignedIn,
            .accountPopoverOtherMarketplaces:
            CGSize(width: 280, height: 240)
        case .signInPanel, .signInPanelExpired: CGSize(width: 400, height: 260)
        case .tileUnselected, .tileSelected, .tileNoCover, .tileLongTitle, .tileNoRuntime, .tileDisabled,
            .tileNotInLibrary, .tileOtherMarketplace,
             .tileQueued, .tileDownloading, .tileExporting, .tileFailed, .tileFailedPartial, .tilePaused,
             .tileDownloaded, .tileExported:
            CGSize(width: 200, height: 280)
        case .gridSignedOut, .gridLoading, .gridCheckingMarketplaces, .gridEmpty, .gridBooks, .gridSelection,
            .gridNoSearchResults:
            CGSize(width: 900, height: 560)
        case .messagesNone, .messagesOne, .messagesSeveral, .messagesNotice: CGSize(width: 700, height: 110)
        case .loginIdle, .loginRegistering, .loginError, .loginPastedURL: CGSize(width: 520, height: 760)
        case .windowSignedOut, .windowLibrary, .windowSelection, .windowLoading, .windowLoadFailed: windowSize
        }
    }

    /// The state's view, framed to its size, on the window background (popover and sheet
    /// content has none of its own).
    static func view(_ state: PreviewState) -> some View {
        let size = size(state)
        return content(state)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func content(_ state: PreviewState) -> AnyView {
        let books = PreviewData.books
        switch state {
        case .avatarInitial: return AnyView(AccountAvatar(name: "Jane Doe", size: 24))
        case .avatarNoName: return AnyView(AccountAvatar(name: nil, size: 24))
        case .avatarLarge: return AnyView(AccountAvatar(name: "Jane Doe", size: 44))

        case .accountButtonSignedOut: return accountButton(name: nil, isSignedIn: false)
        case .accountButtonSignedIn: return accountButton(name: "Jane Doe", isSignedIn: true)
        case .accountButtonLongName: return accountButton(
            name: "Maximiliane Alexandra Featherstonehaugh-Smythe",
            isSignedIn: true)
        case .accountButtonNeedsReauthentication: return accountButton(
            name: nil,
            isSignedIn: false,
            needsReauthentication: true)

        case .accountPopoverSignedOut: return accountPopover(canSignIn: true)
        case .accountPopoverWorking: return accountPopover(canSignIn: false)
        case .accountPopoverExpired: return accountPopover(
            needsReauthentication: true,
            canSignIn: true,
            canSignOut: true)
        case .accountPopoverSignedIn: return accountPopover(account: PreviewData.session, canSignOut: true)
        case .accountPopoverOtherMarketplaces:
            return accountPopover(account: PreviewData.session, otherMarketplaces: [
                LibraryViewModel.MarketplaceCount(marketplace: .uk, count: 12), LibraryViewModel.MarketplaceCount(
                    marketplace: .japan,
                    count: 3),
            ], canSignOut: true)

        case .signInPanel: return signInPanel()
        case .signInPanelExpired: return signInPanel(needsReauthentication: true)

        case .tileUnselected: return tile(books[0])
        case .tileSelected: return tile(books[0], BookTileState(isSelected: true))
        case .tileNoCover: return tile(books[2])
        case .tileLongTitle: return tile(books[4])
        case .tileNoRuntime: return tile(books[7])
        case .tileDisabled: return tile(books[0], canSelect: false)
        case .tileNotInLibrary: return tile(books[1], PreviewData.tileState(isInLibrary: false, status: .downloaded))
        case .tileOtherMarketplace: return tile(books[3], BookTileState(marketplaceBadge: "UK", status: .downloaded))
        case .tileQueued: return tile(books[1], PreviewData.tileState(status: .queued(.download)))
        case .tileDownloading: return tile(
            books[1],
            PreviewData.tileState(status: .running(
                .download,
                progress: 0.4,
                transferred: TransferProgress(bytesReceived: 132_000_000, bytesExpected: 288_000_000))))
        case .tileExporting: return tile(books[1], PreviewData.tileState(status: .running(.export, progress: 0.7)))
        case .tileFailed: return tile(
            books[1],
            PreviewData.tileState(status: .failed(.download, "HTTP 403: Forbidden")))
        case .tileFailedPartial:
            return tile(
                books[1],
                PreviewData.tileState(status: .failed(
                    .download,
                    "The network connection was lost.",
                    kept: PreviewData.kept)))
        case .tilePaused: return tile(books[1], PreviewData.tileState(status: .paused(PreviewData.kept)))
        case .tileDownloaded: return tile(books[1], PreviewData.tileState(status: .downloaded))
        case .tileExported: return tile(books[1], PreviewData.tileState(status: .exported))

        case .gridSignedOut: return grid([], isSignedIn: false)
        case .gridLoading: return grid([], isLoading: true)
        case .gridCheckingMarketplaces: return grid([], isCheckingMarketplaces: true)
        case .gridEmpty: return grid([])
        case .gridBooks: return grid(books)
        case .gridSelection: return grid(books, selected: [books[1].asin, books[3].asin, books[6].asin])
        case .gridNoSearchResults: return grid([], isLibraryEmpty: false)

        case .messagesNone: return AnyView(MessagesBar(messages: []))
        case .messagesOne: return AnyView(
            MessagesBar(messages: ["Could not reach Audible: The Internet connection appears to be offline."]))
        case .messagesSeveral:
            return AnyView(MessagesBar(messages: [
                "Your session expired. Sign in again to continue.",
                """
                Audible returned HTTP 503 (Service Unavailable) while loading page 3 of your library. Try refreshing \
                in a few minutes.
                """,
                "The download folder could not be created or is not writable: /Users/jane/Documents/Loudible",
            ]))
        case .messagesNotice:
            return AnyView(MessagesBar(
                messages: [],
                notices: ["Couldn’t check the Audible Japan, India marketplaces for more titles."]))

        case .loginIdle: return loginSheet()
        case .loginRegistering: return loginSheet(isRegistering: true)
        case .loginError: return loginSheet(errorMessage: ExporterError.loginCallback(.expired).localizedDescription)
        case .loginPastedURL: return loginSheet(
            pastedURL: "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=PREVIEW",
            showsBrowserFallback: true)

        case .windowSignedOut: return window(.preview(signedIn: false))
        case .windowLibrary: return window(.preview())
        case .windowSelection: return window(.preview(), selecting: [books[0].asin, books[4].asin])
        case .windowLoading: return window(.preview(library: .loading))
        case .windowLoadFailed: return window(
            .preview(library: .failing("Audible returned HTTP 500 (Internal Server Error).")))
        }
    }

    // MARK: Builders

    private static func accountButton(name: String?, isSignedIn: Bool, needsReauthentication: Bool = false) -> AnyView {
        AnyView(AccountButtonLabel(name: name, isSignedIn: isSignedIn, needsReauthentication: needsReauthentication))
    }

    private static func accountPopover(
        account: AudibleSession? = nil, otherMarketplaces: [LibraryViewModel.MarketplaceCount] = [],
        needsReauthentication: Bool = false, canSignIn: Bool = false, canSignOut: Bool = false
    ) -> AnyView {
        AnyView(AccountPopoverContent(
            account: account,
            otherMarketplaces: otherMarketplaces,
            needsReauthentication: needsReauthentication,
            marketplace: .constant(.us),
            canChangeMarketplace: canSignIn,
            canSignIn: canSignIn,
            canSignOut: canSignOut,
            signIn: {},
            signOut: {}
        ))
    }

    private static func signInPanel(needsReauthentication: Bool = false) -> AnyView {
        AnyView(SignInPanelContent(
            needsReauthentication: needsReauthentication,
            marketplace: .constant(.us),
            canChangeMarketplace: true,
            canSignIn: true,
            signIn: {}))
    }

    private static func tile(
        _ book: Audiobook,
        _ state: BookTileState = BookTileState(),
        canSelect: Bool = true) -> AnyView {
        AnyView(BookTile(book: book, state: state, canSelect: canSelect, toggle: {}, perform: { _ in
            }).frame(width: 150).padding())
    }

    private static func grid(
        _ books: [Audiobook], selected: Set<String> = [], isLibraryEmpty: Bool? = nil, isSignedIn: Bool = true,
        isLoading: Bool = false,
        isCheckingMarketplaces: Bool = false) -> AnyView {
        AnyView(LibraryGridContent(
            books: books,
            isLibraryEmpty: isLibraryEmpty ?? books.isEmpty,
            isSignedIn: isSignedIn,
            isLoading: isLoading,
            isCheckingMarketplaces: isCheckingMarketplaces,
            canSelect: isSignedIn && !books.isEmpty,
            tile: { book in
                BookTileState(
                    isSelected: selected.contains(book.asin),
                    marketplaceBadge: book.marketplace == PreviewData.session.marketplace ? nil : book.marketplace.id
                    .uppercased(),
                    menuItems: [BookMenuItem(.download)])
            },
            toggle: { _ in },
            perform: { _, _ in }
        ))
    }

    private static func loginSheet(
        isRegistering: Bool = false, errorMessage: String? = nil, pastedURL: String = "",
        showsBrowserFallback: Bool = false) -> AnyView {
        AnyView(LoginSheetContent(
            marketplaceName: Marketplace.us.name,
            isRegistering: isRegistering,
            pastedURL: .constant(pastedURL),
            canSubmitPastedURL: !pastedURL.isEmpty,
            errorMessage: errorMessage,
            showsBrowserFallback: showsBrowserFallback,
            openInBrowser: {},
            submitPastedURL: {},
            cancel: {},
            browser: {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Label("Amazon sign-in page", systemImage: "globe").foregroundStyle(.secondary)
                }
            }))
    }

    /// The whole window, as `LoudibleApp` shows it.
    private static func window(_ model: AppViewModel, selecting asins: Set<String> = []) -> AnyView {
        AnyView(ContentView(model: model).task {
            await model.start()
            model.library.setSelection(asins)
        })
    }
}

/// Sample books, sessions, and logins. All synthetic.
@MainActor
enum PreviewData {
    /// Ten books: varied titles, authors, and runtimes. Books 2 and 8 have no cover, book 7 no runtime.
    /// Books 3 and 8 are from the UK store and book 6 from Japan; the rest from the US (home).
    static let books: [Audiobook] = {
        let colors: [NSColor] = [
            .systemIndigo,
            .systemTeal,
            .systemOrange,
            .systemPink,
            .systemGreen,
            .systemBrown,
            .systemPurple,
            .systemRed
        ]
        func cover(_ index: Int) -> URL? { coverURL(colors[index % colors.count], name: "cover\(index)") }
        return [
            Audiobook(
                asin: "PREVIEW001",
                marketplace: .us,
                title: "The Lighthouse Keeper's Atlas",
                authors: ["Mara Ellison"],
                narrators: ["Tom Avery"],
                runtimeMinutes: 642,
                coverImageURL: cover(0)),
            Audiobook(
                asin: "PREVIEW002",
                marketplace: .us,
                title: "A Short History of Tea",
                authors: ["Henrik Dahl"],
                runtimeMinutes: 318,
                coverImageURL: cover(1)),
            Audiobook(
                asin: "PREVIEW003",
                marketplace: .us,
                title: "Signals from the Deep",
                authors: ["Ada Okafor"],
                runtimeMinutes: 875),
            Audiobook(
                asin: "PREVIEW004",
                marketplace: .uk,
                title: "Winter in Valparaíso",
                authors: ["Lucía Ferrer"],
                narrators: ["Ana Ruiz"],
                runtimeMinutes: 501,
                coverImageURL: cover(3)),
            Audiobook(
                asin: "PREVIEW005",
                marketplace: .us,
                title: "The Clockmaker's Daughter and the Brass Meridian: Being the First Book of the Long Winter Saga",
                subtitle: "A Novel",
                authors: ["Eleanor Whitcombe-Hartley", "Jonathan R. Pemberton", "Siobhán Ní Bhriain"],
                narrators: ["The Full Cast"],
                runtimeMinutes: 1_934,
                coverImageURL: cover(4)),
            Audiobook(
                asin: "PREVIEW006",
                marketplace: .us,
                title: "Notes on Quiet",
                authors: ["Kenji Mori"],
                runtimeMinutes: 196,
                coverImageURL: cover(5)),
            Audiobook(
                asin: "PREVIEW007",
                marketplace: .japan,
                title: "Field Guide to Small Machines",
                authors: ["Priya Raman", "Leo Brandt"],
                runtimeMinutes: 412,
                coverImageURL: cover(6)),
            Audiobook(
                asin: "PREVIEW008",
                marketplace: .us,
                title: "The Seventh Orchard",
                authors: ["Ruth Calloway"],
                coverImageURL: cover(7)),
            Audiobook(
                asin: "PREVIEW009",
                marketplace: .uk,
                title: "Ninety Days North",
                authors: ["Sam Okonkwo"],
                runtimeMinutes: 733),
            Audiobook(
                asin: "PREVIEW010",
                marketplace: .us,
                title: "Paper Rivers",
                authors: ["Ines Varga"],
                runtimeMinutes: 288,
                coverImageURL: cover(1)),
        ]
    }()

    static let session = AudibleSession(
        marketplace: .us,
        device: DeviceIdentity(serial: "PREVIEW0000000000000000000000000"),
        customerID: "preview",
        customerName: "Jane Doe",
        accessToken: "preview",
        accessTokenExpiresAt: .distantFuture,
        refreshToken: "preview",
        adpToken: "preview",
        devicePrivateKey: "preview"
    )

    /// A login whose page never loads: `.invalid` is reserved and never resolves.
    nonisolated static func pendingLogin(for marketplace: Marketplace = .us) -> PendingLogin {
        PendingLogin(
            id: UUID(),
            marketplace: marketplace,
            device: DeviceIdentity(serial: "PREVIEW0000000000000000000000000"),
            codeVerifier: "preview",
            loginURL: URL(string: "https://sign-in.example.invalid/ap/signin")!,
            cookies: [],
            createdAt: Date()
        )
    }

    // MARK: Tiles

    /// Part of an unfinished download kept for later.
    static let kept = TransferProgress(bytesReceived: 132_000_000, bytesExpected: 288_000_000)

    /// A tile with the menu that goes with its status.
    static func tileState(isInLibrary: Bool = true, status: BookStatus) -> BookTileState {
        let items: [BookMenuItem] = switch status {
        case .queued(let kind), .running(let kind, _, _): [BookMenuItem(.cancel(jobID: UUID(), kind: kind))]
        case .downloaded, .exported: [BookMenuItem(.export), BookMenuItem(.showDownload), BookMenuItem(.deleteDownload)]
        case .failed(_, _, _?), .paused: [
            BookMenuItem(.resumeDownload),
            BookMenuItem(.export),
            BookMenuItem(.deleteDownload)
        ]
        case .none, .failed: [BookMenuItem(.download)]
        }
        return BookTileState(isInLibrary: isInLibrary, status: status, menuItems: items)
    }

    // MARK: Covers

    /// Covers are coloured PNGs in a temporary folder, written once: `AsyncImage` needs a URL.
    nonisolated private static func coverURL(_ color: NSColor, name: String) -> URL? {
        let url = coverFolder.appendingPathComponent("\(name).png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let image = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
                color.setFill()
                rect.fill()
                color.blended(withFraction: 0.35, of: .white)?.setFill()
                NSRect(x: 0, y: rect.height * 0.62, width: rect.width, height: rect.height * 0.08).fill()
                return true
            }
            guard let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  (try? png.write(to: url)) != nil
            else { return nil }
        }
        return url
    }

    nonisolated private static let coverFolder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LoudiblePreviews/Covers",
            isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
}

// MARK: - Whole-window models

/// What the fake API answers when the library is loaded.
enum PreviewLibrary: Sendable {
    case books([Audiobook])
    /// Never answers, so the library stays loading.
    case loading
    /// Fails with this message.
    case failing(String)
}

extension AppViewModel {
    /// A model on in-memory fakes, for whole-window previews. Call `start()` to load it, as the
    /// app does; `PreviewCatalog` does that in `.task`.
    @MainActor
    static func preview(
        signedIn: Bool = true,
        library: PreviewLibrary = .books(PreviewData.books)) -> AppViewModel {
        let api = PreviewAPI(library: library)
        let auth = AuthenticationCoordinator(
            api: api,
            store: PreviewCredentialStore(session: signedIn ? PreviewData.session : nil),
            clock: SystemClock())
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoudiblePreviews/\(UUID().uuidString)", isDirectory: true)
        let downloads = LocalDownloads(
            folder: work.appendingPathComponent("Downloads", isDirectory: true),
            manifestFolder: work.appendingPathComponent("Manifests", isDirectory: true),
            trash: { try FileManager.default.removeItem(at: $0) })
        let queue = ExportQueue(
            auth: auth,
            api: api,
            downloader: PreviewDownloader(),
            converter: PreviewConverter(),
            downloads: downloads)
        return AppViewModel(
            session: SessionViewModel(auth: auth),
            library: LibraryViewModel(service: LibraryService(api: api, auth: auth)),
            export: ExportViewModel(queue: queue, exportFolder: downloads.folder),
            downloads: downloads
        )
    }
}

private struct PreviewAPI: AudibleAPI {
    let library: PreviewLibrary

    func makeLogin(for marketplace: Marketplace) throws -> PendingLogin { PreviewData.pendingLogin(for: marketplace) }

    func register(_ login: PendingLogin, authorizationCode: String) async throws -> AudibleSession {
        throw ExporterError.network("Previews cannot sign in.")
    }

    func refresh(_ session: AudibleSession) async throws -> AudibleSession { session }

    func libraryPage(
        _ number: Int,
        pageSize: Int,
        marketplace: Marketplace,
        session: AudibleSession) async throws -> LibraryPage {
        switch library {
        case .books(let books):
            let entries = books.filter { $0.marketplace == marketplace }.map { LibraryEntry(
                book: $0,
                contentDeliveryType: "SinglePartBook",
                contentType: "Product",
                isAYCE: false) }
            return LibraryPage(entries: number == 1 ? entries : [], totalCount: books.count)
        case .loading:
            try await Task.sleep(for: .seconds(365 * 24 * 3600))
            throw ExporterError.cancelled
        case .failing(let message):
            throw ExporterError.network(message)
        }
    }

    func license(for asin: String, marketplace: Marketplace, session: AudibleSession) async throws -> ContentLicense {
        throw ExporterError.licenseDenied(asin: asin, reason: "Previews cannot download.")
    }
}

private struct PreviewCredentialStore: CredentialStore {
    let session: AudibleSession?
    func load() throws -> AudibleSession? { session }
    func save(_ session: AudibleSession) throws {}
    func delete() throws {}
}

private struct PreviewDownloader: FileDownloader {
    func download(
        from url: URL, to destination: URL, resumeData: Data?,
        recovery: @escaping @Sendable (DownloadRecovery) -> Void,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        throw ExporterError.download("Previews cannot download.")
    }
}

private struct PreviewConverter: AudioConverter {
    func convert(_ request: ConversionRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        throw ExporterError.conversion("Previews cannot convert.")
    }
}
#endif
