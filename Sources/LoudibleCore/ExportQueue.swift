import Foundation

/// Schedules downloads and exports.
///
/// - A **download** fetches the encrypted file (license → download → manifest → move into place)
///   and keeps it in `LocalDownloads.folder`.
/// - An **export** converts the kept file to M4B. A book that is not downloaded yet is downloaded
///   first, exactly as a download job would, and the file is kept.
///
/// Jobs for one book run strictly in the order they were queued; up to `maximumConcurrentBooks`
/// different books run at once. Work can be added while jobs run. A failed job does not stop the
/// others, finished files are never touched again, and partial files are removed whatever the
/// outcome. When Audible requires a new sign-in, the affected jobs pause until
/// `resumeAfterAuthentication()` or `cancel()`, and no new job starts meanwhile.
public actor ExportQueue {
    public struct Snapshot: Sendable, Equatable {
        public var jobs: [ExportJob]
        public var isRunning: Bool
        public var isWaitingForAuthentication: Bool

        public init(jobs: [ExportJob] = [], isRunning: Bool = false, isWaitingForAuthentication: Bool = false) {
            self.jobs = jobs
            self.isRunning = isRunning
            self.isWaitingForAuthentication = isWaitingForAuthentication
        }

        /// Completion across all jobs (0...1).
        public var fractionCompleted: Double {
            guard !jobs.isEmpty else { return 0 }
            return jobs.map(\.fractionCompleted).reduce(0, +) / Double(jobs.count)
        }
    }

    public enum StartError: Error, Equatable {
        case nothingToExport
        case destinationUnavailable(String)
    }

    /// Appended to a conversion error when the input was a kept download, which may be damaged.
    static let redownloadHint = "If this keeps failing, delete the download and download it again."

    private let auth: AuthenticationCoordinator
    private let api: any AudibleAPI
    private let downloader: any FileDownloader
    private let converter: any AudioConverter
    private let downloads: LocalDownloads
    private let maximumConcurrentBooks: Int
    private let fileManager = FileManager.default

    private var snapshot = Snapshot() {
        didSet {
            guard snapshot != oldValue else { return }
            for continuation in observers.values { continuation.yield(snapshot) }
        }
    }
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var running: [UUID: Task<Void, Never>] = [:]
    private var exportDestinations: [UUID: URL] = [:]
    private var authenticationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - downloads: where downloads are kept, with their manifests.
    ///   - maximumConcurrentBooks: how many different books may be worked on at once.
    public init(
        auth: AuthenticationCoordinator,
        api: any AudibleAPI,
        downloader: any FileDownloader,
        converter: any AudioConverter,
        downloads: LocalDownloads,
        maximumConcurrentBooks: Int = 3
    ) {
        self.auth = auth
        self.api = api
        self.downloader = downloader
        self.converter = converter
        self.downloads = downloads
        self.maximumConcurrentBooks = max(1, maximumConcurrentBooks)
    }

    public var currentSnapshot: Snapshot { snapshot }

    /// Emits the current snapshot, then every change.
    public func updates() -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        observers[id] = continuation
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: Control

    /// Exports `books` into `destination`. Returns once the jobs are queued.
    public func start(_ books: [Audiobook], destination: URL) throws(StartError) {
        try enqueue(books, kind: .export, exportDestination: destination)
    }

    /// Queues one job of `kind` per book and returns the ids of the jobs it added. Books that
    /// already have an unfinished job of that kind are skipped, and so is a download of a book
    /// with an unfinished export, which downloads it anyway.
    /// - Parameter exportDestination: required for `.export`, ignored for `.download`.
    @discardableResult
    public func enqueue(_ books: [Audiobook], kind: ExportJob.Kind, exportDestination: URL?) throws(StartError) -> [UUID] {
        var seen = Set<String>()
        let unique = books.filter { seen.insert($0.asin).inserted }
        guard !unique.isEmpty else { throw .nothingToExport }

        // First, so an export destination that is the downloads folder exists before it is checked.
        do {
            try downloads.ensureFolder()
        } catch {
            throw .destinationUnavailable(downloads.folder.path)
        }
        if kind == .export {
            guard let exportDestination else { throw .destinationUnavailable("") }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: exportDestination.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  fileManager.isWritableFile(atPath: exportDestination.path)
            else { throw .destinationUnavailable(exportDestination.path) }
        }

        // A new run starts with a clean list; finished jobs of the last run are dropped.
        if !snapshot.isRunning {
            snapshot.jobs.removeAll()
            exportDestinations.removeAll()
        }
        let pending = snapshot.jobs.filter { !$0.state.isFinished }
        var added: [UUID] = []
        for book in unique {
            let covered = pending.contains { job in
                job.book.asin == book.asin && (job.kind == kind || (kind == .download && job.kind == .export))
            }
            guard !covered else { continue }
            let job = ExportJob(book: book, kind: kind)
            snapshot.jobs.append(job)
            if kind == .export { exportDestinations[job.id] = exportDestination }
            added.append(job.id)
        }
        if !added.isEmpty { snapshot.isRunning = true }
        schedule()
        return added
    }

    /// Cancels every running and queued job. Completed ones are kept.
    public func cancel() {
        for index in snapshot.jobs.indices where snapshot.jobs[index].state == .queued {
            update(snapshot.jobs[index].id, to: .cancelled)
        }
        for task in running.values { task.cancel() }
        finishIfIdle()
    }

    /// Cancels one job: a running one stops, a queued one is skipped. Finished jobs and unknown
    /// ids are ignored.
    public func cancel(_ id: UUID) {
        if let task = running[id] {
            task.cancel()
        } else if let index = index(of: id), snapshot.jobs[index].state == .queued {
            update(id, to: .cancelled)
            schedule()
        }
    }

    /// Forgets the jobs of a finished run. Ignored while jobs are running.
    public func clear() {
        guard !snapshot.isRunning else { return }
        snapshot = Snapshot()
        exportDestinations.removeAll()
    }

    /// Continues every job paused for sign-in.
    public func resumeAfterAuthentication() {
        let waiters = authenticationWaiters.values
        authenticationWaiters.removeAll()
        snapshot.isWaitingForAuthentication = false
        waiters.forEach { $0.resume() }
        schedule()
    }

    /// Waits until no job is queued or running.
    public func waitUntilFinished() async {
        guard snapshot.isRunning else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    // MARK: Scheduling

    /// Starts queued jobs in order, one per book, while there is capacity and nobody waits for sign-in.
    private func schedule() {
        defer { finishIfIdle() }
        guard !snapshot.isWaitingForAuthentication else { return }
        // A book is blocked once an earlier unfinished job of it is seen, so its jobs keep their order.
        var blocked = Set<String>()
        for job in snapshot.jobs where !job.state.isFinished {
            let asin = job.book.asin
            guard !blocked.contains(asin) else { continue }
            blocked.insert(asin)
            guard job.state == .queued, running[job.id] == nil, running.count < maximumConcurrentBooks else { continue }
            let id = job.id
            running[id] = Task {
                await self.process(id)
                self.jobEnded(id)
            }
        }
    }

    private func jobEnded(_ id: UUID) {
        running[id] = nil
        exportDestinations[id] = nil
        schedule()
    }

    private func finishIfIdle() {
        guard snapshot.isRunning, running.isEmpty, !snapshot.jobs.contains(where: { !$0.state.isFinished }) else { return }
        snapshot.isRunning = false
        snapshot.isWaitingForAuthentication = false
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: Processing

    private func process(_ id: UUID) async {
        guard let index = index(of: id) else { return }
        let job = snapshot.jobs[index]
        while true {
            do {
                let output = try await runOnce(id, job: job)
                update(id, to: .completed(output))
                return
            } catch .authenticationRequired {
                update(id, to: .waitingForAuthentication)
                await waitForAuthentication(id)
                if Task.isCancelled {
                    update(id, to: .cancelled)
                    return
                }
                // A paused job restarts from licensing, whatever phase it then skips to.
                update(id, to: .running(.licensing, progress: 0))
            } catch .cancelled {
                update(id, to: .cancelled)
                return
            } catch {
                if Task.isCancelled {
                    update(id, to: .cancelled)
                } else {
                    update(id, to: .failed("\(job.book.title): \(error.localizedDescription)"))
                }
                return
            }
        }
    }

    private func runOnce(_ id: UUID, job: ExportJob) async throws(ExporterError) -> URL {
        switch job.kind {
        case .download:
            return try await downloadOnce(id, book: job.book)
        case .export:
            guard let destination = exportDestinations[id] else { throw .unexpected("No export folder.") }
            return try await exportOnce(id, book: job.book, destination: destination)
        }
    }

    private func downloadOnce(_ id: UUID, book: Audiobook) async throws(ExporterError) -> URL {
        // There is no re-download: a kept file is the result.
        if let existing = downloads.scanDownloads()[book.asin] {
            update(id, to: .running(.finalizing, progress: 0))
            return existing
        }
        update(id, to: .running(.licensing, progress: 0))
        let license = try await fetchLicense(for: book)
        try checkCancellation()
        return try await download(id, book: book, license: license, kind: .download)
    }

    private func exportOnce(_ id: UUID, book: Audiobook, destination: URL) async throws(ExporterError) -> URL {
        var license: ContentLicense?
        let input: URL
        let isKeptDownload: Bool
        if let existing = downloads.scanDownloads()[book.asin] {
            input = existing
            isKeptDownload = true
        } else {
            update(id, to: .running(.licensing, progress: 0))
            let fresh = try await fetchLicense(for: book)
            try checkCancellation()
            input = try await download(id, book: book, license: fresh, kind: .export)
            license = fresh
            isKeptDownload = false
        }

        // Keys: from the license just used, else the manifest, else a fresh license.
        let decryption: ContentLicense.Decryption
        let chapters: [Chapter]
        if let license {
            (decryption, chapters) = (license.decryption, license.chapters)
        } else if let manifest = downloads.manifest(for: book.asin) {
            (decryption, chapters) = (manifest.decryption, manifest.chapters)
        } else {
            update(id, to: .running(.licensing, progress: 0))
            let fresh = try await fetchLicense(for: book)
            (decryption, chapters) = (fresh.decryption, fresh.chapters)
        }
        try checkCancellation()

        let base = ExportFileNaming.baseName(for: book)
        let partial = destination.appendingPathComponent(ExportFileNaming.partialName(base: base, token: UUID().uuidString))
        defer { try? fileManager.removeItem(at: partial) }

        update(id, to: .running(.converting, progress: 0))
        let request = ConversionRequest(
            input: input, output: partial, decryption: decryption, chapters: chapters, metadata: BookMetadata(book: book)
        )
        do {
            try await perform {
                try await self.converter.convert(request, progress: self.progressHandler(id, .converting))
            }
        } catch .conversion(let detail) where isKeptDownload {
            throw .conversion("\(detail) \(Self.redownloadHint)")
        }
        try checkCancellation()
        guard fileManager.fileExists(atPath: partial.path) else {
            throw .conversion("The converter did not produce an output file.")
        }

        update(id, to: .running(.finalizing, progress: 0))
        return try moveIntoPlace(partial, directory: destination, base: base, extension: ExportFileNaming.fileExtension)
    }

    private func fetchLicense(for book: Audiobook) async throws(ExporterError) -> ContentLicense {
        let api = self.api
        return try await auth.withValidSession { session in
            try await api.license(for: book.asin, marketplace: book.marketplace, session: session)
        }
    }

    /// Downloads into a hidden partial in the downloads folder, writes the manifest, then moves
    /// the file to `Title [ASIN].<ext>`. The partial is removed whatever happens.
    private func download(_ id: UUID, book: Audiobook, license: ContentLicense, kind: ExportJob.Kind) async throws(ExporterError) -> URL {
        let ext = license.decryption.fileExtension
        let base = ExportFileNaming.baseName(for: book, extension: ext)
        let token = UUID().uuidString
        let partial = downloads.folder.appendingPathComponent(ExportFileNaming.partialName(base: base, token: token))
        let cover = downloads.manifestFolder.appendingPathComponent(".\(book.asin).\(token).cover")
        defer {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: cover)
        }

        update(id, to: .running(.downloading, progress: 0))
        try await perform {
            try await self.downloader.download(from: license.downloadURL, to: partial, progress: self.progressHandler(id, .downloading))
        }
        try checkCancellation()

        if kind == .download { update(id, to: .running(.finalizing, progress: 0)) }
        // The cover is a nicety for books that later leave the library; failing to get it is fine.
        if let coverURL = book.coverImageURL {
            try? await downloader.download(from: coverURL, to: cover, progress: { _ in })
        }
        try checkCancellation()
        let manifest = DownloadManifest(book: book, decryption: license.decryption, chapters: license.chapters, downloadedAt: Date())
        try downloads.writeManifest(manifest, coverFile: fileManager.fileExists(atPath: cover.path) ? cover : nil)
        do {
            return try moveIntoPlace(partial, directory: downloads.folder, base: base, extension: ext)
        } catch {
            downloads.removeManifest(asin: book.asin)
            throw error
        }
    }

    /// Moves a finished file to the first free `Title [ASIN] (n).<ext>` name. `moveItem`
    /// refuses to overwrite, so a file appearing concurrently just bumps the suffix.
    private func moveIntoPlace(_ partial: URL, directory: URL, base: String, extension ext: String) throws(ExporterError) -> URL {
        var attempt = 1
        while attempt < 10_000 {
            let candidate = directory.appendingPathComponent(ExportFileNaming.fileName(base: base, attempt: attempt, extension: ext))
            if !fileManager.fileExists(atPath: candidate.path) {
                do {
                    try fileManager.moveItem(at: partial, to: candidate)
                    return candidate
                } catch {
                    guard fileManager.fileExists(atPath: candidate.path) else {
                        throw .fileSystem("Could not move the file into place: \(error.localizedDescription)")
                    }
                }
            }
            attempt += 1
        }
        throw .fileSystem("Too many files named \(base).")
    }

    private func perform(_ operation: () async throws -> Void) async throws(ExporterError) {
        do {
            try await operation()
        } catch {
            throw ExporterError.from(error)
        }
    }

    private func checkCancellation() throws(ExporterError) {
        if Task.isCancelled { throw .cancelled }
    }

    private nonisolated func progressHandler(_ id: UUID, _ phase: ExportJob.Phase) -> @Sendable (Double) -> Void {
        { [weak self] progress in
            Task { await self?.reportProgress(id, phase, progress) }
        }
    }

    private func reportProgress(_ id: UUID, _ phase: ExportJob.Phase, _ progress: Double) {
        guard let index = index(of: id),
              case .running(let currentPhase, let current) = snapshot.jobs[index].state,
              currentPhase == phase,
              progress >= 1 || progress - current >= 0.005
        else { return }
        update(id, to: .running(phase, progress: min(max(progress, 0), 1)))
    }

    private func index(of id: UUID) -> Int? {
        snapshot.jobs.firstIndex { $0.id == id }
    }

    private func update(_ id: UUID, to state: ExportJob.State) {
        guard let index = index(of: id) else { return }
        // Late or out-of-order progress reports are invalid transitions and simply dropped.
        try? snapshot.jobs[index].transition(to: state)
    }

    // MARK: Authentication pause

    private func waitForAuthentication(_ id: UUID) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    authenticationWaiters[id] = continuation
                    snapshot.isWaitingForAuthentication = true
                }
            }
        } onCancel: {
            Task { await self.wakeAuthenticationWaiter(id) }
        }
    }

    private func wakeAuthenticationWaiter(_ id: UUID) {
        authenticationWaiters.removeValue(forKey: id)?.resume()
        if authenticationWaiters.isEmpty {
            snapshot.isWaitingForAuthentication = false
            schedule()
        }
    }
}
