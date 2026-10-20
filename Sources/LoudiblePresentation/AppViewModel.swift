import Foundation
import Observation
import LoudibleCore

/// Connects the session, library, and export models: signing in loads the library,
/// signing out clears it, and a new sign-in resumes jobs paused for authentication. Also keeps
/// track of which books are downloaded, exported or partly downloaded, from the files on disk,
/// and continues the unfinished downloads of the signed-in account.
@MainActor
@Observable
public final class AppViewModel {
    public let session: SessionViewModel
    public let library: LibraryViewModel
    public let export: ExportViewModel

    /// Downloaded audio files by ASIN, from the last rescan.
    public private(set) var downloadedFiles: [String: URL] = [:]
    /// Exported M4B files by ASIN, from the last rescan.
    public private(set) var exportedFiles: [String: URL] = [:]
    /// Unfinished downloads kept to be continued, by ASIN, from the last rescan.
    public private(set) var partialDownloads: [String: TransferProgress] = [:]
    private var manifestASINs: Set<String> = []

    @ObservationIgnored private let downloads: LocalDownloads
    @ObservationIgnored private var lastSessionDevice: DeviceIdentity?
    @ObservationIgnored private var started = false

    public init(
        session: SessionViewModel,
        library: LibraryViewModel,
        export: ExportViewModel,
        downloads: LocalDownloads) {
        self.session = session
        self.library = library
        self.export = export
        self.downloads = downloads
    }

    public func start() async {
        guard !started else { return }
        started = true
        // Unfinished downloads are kept; other leftovers of an interrupted run are not.
        let downloads = self.downloads
        await Task.detached { downloads.sweepPartials() }.value
        export.onJobFinished = { [weak self] in
            Task { await self?.rescan() }
        }
        await export.start()
        await session.start()
        await sessionChanged()
        await rescan()
        observeSession()
    }

    private func observeSession() {
        withObservationTracking {
            _ = session.authState
            _ = export.isWaitingForAuthentication
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.sessionChanged()
                self.observeSession()
            }
        }
    }

    /// Reacts to sign-in state; public so tests can drive it deterministically.
    public func sessionChanged() async {
        library.isSignedIn = session.isSignedIn
        let device = session.session?.device
        defer { lastSessionDevice = device }

        guard session.isSignedIn else {
            if !session.needsReauthentication, lastSessionDevice != nil { library.reset() }
            return
        }
        if export.isWaitingForAuthentication {
            await export.resumeAfterAuthentication()
        }
        // A restored or new sign-in loads the library; token refreshes keep the device and do not.
        if device != lastSessionDevice {
            await refreshLibrary()
        }
    }

    /// Reloads the library, then the downloaded books shown with it, then continues the
    /// unfinished downloads.
    public func refreshLibrary() async {
        await library.refresh()
        await rescan()
        await reconcilePartialDownloads()
    }

    /// Continues the signed-in account's unfinished downloads, except those that failed in this
    /// session (they wait for Resume Download), and deletes the ones that can't be continued:
    /// another account's, ones of unknown size, and books no longer in the library. Does nothing
    /// unless the library loaded completely, so a failed refresh never deletes anything.
    public func reconcilePartialDownloads() async {
        guard let customerID = session.session?.customerID,
              library.loadState == .loaded, !library.isCheckingMarketplaces
        else { return }
        let downloads = self.downloads
        let records = await Task.detached { downloads.partialDownloads() }.value
        let busy = Set(export.jobs.filter { !$0.state.isFinished }.map(\.book.asin))
        var discard: [String] = []
        var resume: [Audiobook] = []
        for record in records where !busy.contains(record.book.asin) {
            let asin = record.book.asin
            if record.customerID != customerID || record.checkpoint.expectedLength <= 0 {
                discard.append(asin)
            } else if !library.isInLibrary(asin) {
                // A store that couldn't be checked may still hold it.
                if library.uncheckedMarketplaces.isEmpty { discard.append(asin) }
            } else if export.failures[asin] == nil {
                resume.append(library.books.first { $0.asin == asin } ?? record.book)
            }
        }
        if !discard.isEmpty {
            await Task.detached { discard.forEach(downloads.removePartialDownload(asin:)) }.value
        }
        if !resume.isEmpty { await export.download(resume) }
        if !discard.isEmpty || !resume.isEmpty { await rescan() }
    }

    // MARK: Files on disk

    /// Rereads the download and export folders. Manifests whose audio file is gone are deleted,
    /// except for books with a job in progress (a download writes its manifest before the file
    /// gets its final name).
    public func rescan() async {
        let downloads = self.downloads
        let exportFolder = export.exportFolder
        let busy = Set(export.jobs.filter { !$0.state.isFinished }.map(\.book.asin))
        let result = await Task.detached {
            let downloaded = downloads.scanDownloads()
            downloads.removeOrphanedManifests(keeping: Set(downloaded.keys).union(busy))
            let manifests = downloads.manifests()
            let exported = downloads.scanExports(in: exportFolder)
            let localBooks = manifests.filter { downloaded[$0.book.asin] != nil }.map { manifest in
                var book = manifest.book
                // The stored cover still shows once Audible's image URL is gone.
                if let cover = downloads.coverURL(for: book.asin) { book.coverImageURL = cover }
                return book
            }
            var partials: [String: TransferProgress] = [:]
            for record in downloads.partialDownloads() {
                partials[record.book.asin] = downloads.partialProgress(for: record)
            }
            return (downloaded, exported, Set(manifests.map(\.book.asin)), localBooks, partials)
        }.value
        (downloadedFiles, exportedFiles, manifestASINs, partialDownloads) = (result.0, result.1, result.2, result.4)
        library.applyLocal(result.3)
    }

    // MARK: Per-book state

    public func status(for book: Audiobook) -> BookStatus {
        BookStatus.resolve(
            asin: book.asin,
            jobs: export.jobs,
            failure: export.failures[book.asin],
            partial: partialDownloads[book.asin],
            isDownloaded: downloadedFiles[book.asin] != nil,
            isExported: exportedFiles[book.asin] != nil
        )
    }

    public func menuItems(for book: Audiobook) -> [BookMenuItem] {
        BookMenu.items(
            asin: book.asin,
            jobs: export.jobs,
            context: BookMenu.Context(
                isDownloaded: downloadedFiles[book.asin] != nil,
                isExported: exportedFiles[book.asin] != nil,
                isInLibrary: library.isInLibrary(book.asin),
                hasManifest: manifestASINs.contains(book.asin),
                isSignedIn: session.isSignedIn,
                hasPartialDownload: partialDownloads[book.asin] != nil
            )
        )
    }

    /// Runs the queue-backed menu actions. Showing files in Finder and the delete confirmation
    /// are up to the view.
    public func perform(_ action: BookAction, on book: Audiobook) async {
        switch action {
        case .download, .resumeDownload:
            await export.download([book])
        case .cancel(let jobID, _):
            await export.cancel(jobID: jobID)
        case .export:
            await export.exportOne(book)
        case .deleteDownload:
            await deleteDownload(book)
        case .showDownload, .showExport:
            break
        }
    }

    // MARK: Selection

    /// The selected books whose menu offers `action` enabled, i.e. the ones the toolbar's
    /// Download or Export button acts on. Download includes Resume Download.
    public func selectedBooks(offering action: BookAction) -> [Audiobook] {
        let actions: Set<BookAction> = action == .download ? [.download, .resumeDownload] : [action]
        return library.selectedBooks.filter { book in
            menuItems(for: book).contains { actions.contains($0.action) && $0.isEnabled }
        }
    }

    /// Downloads or exports the selected books that offer it, as their menus would, then clears
    /// the selection.
    public func performOnSelection(_ action: BookAction) async {
        let books = selectedBooks(offering: action)
        guard !books.isEmpty else { return }
        switch action {
        case .download: await export.download(books)
        case .export: await export.export(books)
        default: return
        }
        library.clearSelection()
    }

    /// Moves the book's audio file to the Trash and deletes its manifest and any unfinished
    /// download; the M4B is kept.
    public func deleteDownload(_ book: Audiobook) async {
        let downloads = self.downloads
        let asin = book.asin
        let result = await Task.detached { () -> Result<Void, ExporterError> in
            do throws(ExporterError) {
                try downloads.trashDownload(asin: asin)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        if case .failure(let error) = result { export.errorMessage = error.localizedDescription }
        await rescan()
    }

    public var hasActiveJobs: Bool { export.activeJobCount > 0 }

    /// Stops every job, then signs out. Downloads in progress keep their bytes and continue
    /// after signing in to the same account again; exports and jobs that hadn't started are
    /// dropped. Finished downloads and exports are kept.
    public func signOut() async {
        await export.suspend()
        await session.signOut()
        await rescan()
    }
}
