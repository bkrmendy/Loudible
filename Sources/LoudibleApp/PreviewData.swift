#if DEBUG
import AppKit
import LoudibleCore
import LoudiblePresentation
import SwiftUI

// Synthetic data and in-memory fakes for source-local previews and the snapshot runner. Nothing here
// contacts Audible: logins point at `.invalid` hosts and the API never touches the network.

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
    /// app does; whole-window previews do that in `.task`.
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
        progress: @escaping @Sendable (DownloadProgress) -> Void
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
