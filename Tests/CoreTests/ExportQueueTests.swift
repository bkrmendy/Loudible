import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct ExportQueueTests {
    let api = MockAudibleAPI()
    let store = InMemoryCredentialStore(Fixtures.session())
    let downloader = MockDownloader()
    let converter = MockConverter()
    let destination: TemporaryDirectory
    let work: TemporaryDirectory
    let downloads: LocalDownloads

    init() throws {
        destination = try TemporaryDirectory("export-destination")
        work = try TemporaryDirectory("export-work")
        downloads = LocalDownloads(
            folder: work.url.appendingPathComponent("Downloads", isDirectory: true),
            manifestFolder: work.url.appendingPathComponent("Manifests", isDirectory: true),
            trash: { try FileManager.default.removeItem(at: $0) }
        )
        api.licenseHandler.withLock { $0 = { asin, _ in Fixtures.license(asin: asin) } }
    }

    /// One book at a time unless a test is about concurrency, so the order is deterministic.
    func makeQueue(maximumConcurrentBooks: Int = 1) async throws -> (ExportQueue, AuthenticationCoordinator) {
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        try await auth.restore()
        let queue = ExportQueue(
            auth: auth, api: api, downloader: downloader, converter: converter,
            downloads: downloads, maximumConcurrentBooks: maximumConcurrentBooks
        )
        return (queue, auth)
    }

    func books(_ count: Int) -> [Audiobook] {
        (1...count).map { Fixtures.book("B00000000\($0)", title: "Book \($0)") }
    }

    func runToCompletion(_ books: [Audiobook], kind: ExportJob.Kind = .export) async throws -> ExportQueue.Snapshot {
        let (queue, _) = try await makeQueue()
        try await queue.enqueue(books, kind: kind, exportDestination: destination.url)
        await queue.waitUntilFinished()
        return await queue.currentSnapshot
    }

    /// Everything in the downloads folder, hidden files included.
    func downloadsContents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: downloads.folder.path)) ?? []).sorted()
    }

    func manifestContents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: downloads.manifestFolder.path)) ?? []).sorted()
    }

    /// A kept download as an earlier run would have left it.
    func keepDownload(_ book: Audiobook, name: String? = nil, withManifest: Bool = true) throws -> URL {
        try downloads.ensureFolder()
        let url = downloads.folder.appendingPathComponent(name ?? "\(book.title) [\(book.asin)].aaxc")
        try Data("kept".utf8).write(to: url)
        if withManifest {
            let manifest = DownloadManifest(
                book: book, decryption: .aax(activationBytes: Data([1, 2, 3, 4])),
                chapters: [Chapter(title: "Stored", startMilliseconds: 0, lengthMilliseconds: 1)], downloadedAt: Fixtures.referenceDate
            )
            try downloads.writeManifest(manifest)
        }
        return url
    }

    func cleanUp() {
        destination.cleanUp()
        work.cleanUp()
    }

    // MARK: Export success

    @Test func exportsSequentiallyWithSanitizedNamesAndKeepsDownloads() async throws {
        defer { cleanUp() }
        let order = Locked<[String]>([])
        converter.handler.withLock {
            $0 = { request in
                order.withLock { $0.append("convert \(request.metadata.asin)") }
                try Data("m4b".utf8).write(to: request.output)
            }
        }
        downloader.handler.withLock {
            $0 = { source, destination in
                order.withLock { $0.append("download \(source.lastPathComponent)") }
                try Data("enc".utf8).write(to: destination)
            }
        }
        let snapshot = try await runToCompletion([
            Fixtures.book("B000000001", title: "Dune: Messiah"), Fixtures.book("B000000002", title: "Other"),
        ])

        #expect(order.current == [
            "download B000000001.aaxc", "convert B000000001", "download B000000002.aaxc", "convert B000000002",
        ])
        #expect(destination.contents() == ["Dune - Messiah [B000000001].m4b", "Other [B000000002].m4b"])
        #expect(snapshot.jobs.map(\.state) == [
            .completed(destination.url.appendingPathComponent("Dune - Messiah [B000000001].m4b")),
            .completed(destination.url.appendingPathComponent("Other [B000000002].m4b")),
        ])
        #expect(!snapshot.isRunning)
        #expect(snapshot.fractionCompleted == 1)
        // An export downloads exactly as a download job would, and keeps the file.
        #expect(downloadsContents() == ["Dune - Messiah [B000000001].aaxc", "Other [B000000002].aaxc"])
        #expect(manifestContents() == ["B000000001.json", "B000000002.json"])
    }

    @Test func passesLicenseAndBookToConverter() async throws {
        defer { cleanUp() }
        _ = try await runToCompletion(books(1))
        let request = try #require(converter.requests.current.first)
        let license = Fixtures.license(asin: "B000000001")
        #expect(request.decryption == license.decryption)
        #expect(request.chapters == license.chapters)
        #expect(request.metadata == BookMetadata(book: books(1)[0]))
        #expect(request.input.standardizedFileURL == downloads.folder.appendingPathComponent("Book 1 [B000000001].aaxc").standardizedFileURL)
        // Temporary output lives next to the destination so the final move is atomic.
        #expect(request.output.deletingLastPathComponent().standardizedFileURL == destination.url.standardizedFileURL)
        #expect(request.output.lastPathComponent.hasPrefix("."))
    }

    @Test func requestsLicenseFromTheBooksMarketplace() async throws {
        defer { cleanUp() }
        let book = Fixtures.book("B000000001", title: "Book 1", marketplace: .uk)
        let snapshot = try await runToCompletion([book], kind: .download)
        #expect(snapshot.jobs.allSatisfy { $0.state.isFinished })
        #expect(api.requestedLicenseMarketplaces.current == [.uk])
        #expect(downloads.manifest(for: book.asin)?.book.marketplace == .uk)
    }

    @Test func numbersCollidingNames() async throws {
        defer { cleanUp() }
        let existing = destination.url.appendingPathComponent("Book 1 [B000000001].m4b")
        try Data("keep me".utf8).write(to: existing)
        let snapshot = try await runToCompletion(books(1) + books(1).map { _ in Fixtures.book("B000000001", title: "dup") })
        #expect(snapshot.jobs.count == 1) // duplicate ASINs are exported once
        #expect(destination.contents() == ["Book 1 [B000000001] (2).m4b", "Book 1 [B000000001].m4b"])
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
    }

    @Test func reportsPhasesAndProgress() async throws {
        defer { cleanUp() }
        let downloadGate = AsyncGate(), convertGate = AsyncGate()
        downloader.handler.withLock { $0 = { _, destination in await downloadGate.wait(); try Data().write(to: destination) } }
        converter.handler.withLock { $0 = { request in await convertGate.wait(); try Data().write(to: request.output) } }
        let (queue, _) = try await makeQueue()
        let updates = await queue.updates()
        try await queue.start(books(2), destination: destination.url)

        // MockDownloader reports 0.5 before waiting on the gate.
        try await waitUntil { await queue.currentSnapshot.jobs[0].state == .running(.downloading, progress: 0.5) }
        var snapshot = await queue.currentSnapshot
        #expect(snapshot.isRunning)
        #expect(snapshot.jobs[1].state == .queued)
        #expect(abs(snapshot.fractionCompleted - (0.02 + 0.58 * 0.5) / 2) < 0.0001)

        await downloadGate.open()
        try await waitUntil { await queue.currentSnapshot.jobs[0].state == .running(.converting, progress: 0.5) }
        await convertGate.open()
        await queue.waitUntilFinished()

        snapshot = await queue.currentSnapshot
        #expect(snapshot.fractionCompleted == 1)
        // Observers receive the latest snapshot.
        var latest: ExportQueue.Snapshot?
        for await update in updates {
            latest = update
            if !update.isRunning { break }
        }
        #expect(latest == snapshot)
    }

    // MARK: Downloads

    @Test func downloadJobKeepsFileAndWritesManifest() async throws {
        defer { cleanUp() }
        let snapshot = try await runToCompletion(books(1), kind: .download)
        let file = downloads.folder.appendingPathComponent("Book 1 [B000000001].aaxc")
        #expect(snapshot.jobs.map(\.state) == [.completed(file)])
        #expect(downloadsContents() == ["Book 1 [B000000001].aaxc"])
        #expect(converter.requests.current.isEmpty)
        #expect(destination.contents().isEmpty)

        let manifest = try #require(downloads.manifest(for: "B000000001"))
        let license = Fixtures.license(asin: "B000000001")
        #expect(manifest.decryption == license.decryption)
        #expect(manifest.chapters == license.chapters)
        #expect(manifest.book == books(1)[0])
        #expect(manifest.fileExtension == "aaxc")
    }

    @Test func legacyAAXDownloadGetsAAXExtension() async throws {
        defer { cleanUp() }
        api.licenseHandler.withLock {
            $0 = { asin, _ in
                ContentLicense(asin: asin, decryption: .aax(activationBytes: Data([1, 2, 3, 4])), downloadURL: URL(string: "https://cdn.example.invalid/x.aax")!, chapters: [])
            }
        }
        _ = try await runToCompletion(books(1), kind: .download)
        #expect(downloadsContents() == ["Book 1 [B000000001].aax"])
    }

    @Test func alreadyDownloadedBookCompletesWithoutLicenseOrDownload() async throws {
        defer { cleanUp() }
        let kept = try keepDownload(books(1)[0], name: "Renamed by user [B000000001].aaxc")
        let snapshot = try await runToCompletion(books(1), kind: .download)
        #expect(snapshot.jobs.map(\.state) == [.completed(kept)])
        #expect(api.requestedLicenses.current.isEmpty)
        #expect(downloader.downloads.current.isEmpty)
    }

    @Test func exportOfDownloadedBookUsesLocalFileAndStoredKeys() async throws {
        defer { cleanUp() }
        let kept = try keepDownload(books(1)[0])
        let snapshot = try await runToCompletion(books(1))
        #expect(api.requestedLicenses.current.isEmpty)
        #expect(downloader.downloads.current.isEmpty)
        let request = try #require(converter.requests.current.first)
        #expect(request.input == kept)
        #expect(request.decryption == .aax(activationBytes: Data([1, 2, 3, 4])))
        #expect(request.chapters.map(\.title) == ["Stored"])
        #expect(snapshot.jobs.map(\.state) == [.completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b"))])
        #expect(try Data(contentsOf: kept) == Data("kept".utf8)) // the download is never deleted
    }

    @Test func exportOfDownloadedBookWithoutManifestGetsFreshKeysButDoesNotDownload() async throws {
        defer { cleanUp() }
        let kept = try keepDownload(books(1)[0], withManifest: false)
        _ = try await runToCompletion(books(1))
        #expect(api.requestedLicenses.current == ["B000000001"])
        #expect(downloader.downloads.current.isEmpty)
        let request = try #require(converter.requests.current.first)
        #expect(request.input == kept)
        #expect(request.decryption == Fixtures.license(asin: "B000000001").decryption)
    }

    @Test func failedConversionOfKeptDownloadSuggestsDownloadingAgain() async throws {
        defer { cleanUp() }
        _ = try keepDownload(books(1)[0])
        converter.handler.withLock { $0 = { _ in throw ExporterError.conversion("bad packet") } }
        let snapshot = try await runToCompletion(books(1))
        guard case .failed(let message) = snapshot.jobs[0].state else { Issue.record("not failed"); return }
        #expect(message.hasSuffix("If this keeps failing, delete the download and download it again."))
    }

    @Test func downloadThenExportOfOneBookRunInOrderAndShareTheFile() async throws {
        defer { cleanUp() }
        let events = Locked<[String]>([])
        let gate = AsyncGate()
        downloader.handler.withLock {
            $0 = { _, destination in
                events.withLock { $0.append("download start") }
                await gate.wait()
                try Data("enc".utf8).write(to: destination)
                events.withLock { $0.append("download end") }
            }
        }
        converter.handler.withLock {
            $0 = { request in
                events.withLock { $0.append("convert") }
                try Data("m4b".utf8).write(to: request.output)
            }
        }
        let (queue, _) = try await makeQueue(maximumConcurrentBooks: 3)
        try await queue.enqueue(books(1), kind: .download, exportDestination: nil)
        try await queue.enqueue(books(1), kind: .export, exportDestination: destination.url)
        try await waitUntil { events.current == ["download start"] }
        #expect(await queue.currentSnapshot.jobs[1].state == .queued)
        await gate.open()
        await queue.waitUntilFinished()

        #expect(events.current == ["download start", "download end", "convert"])
        #expect(downloader.downloads.current.count == 1)
        #expect(api.requestedLicenses.current == ["B000000001"])
        #expect(await queue.currentSnapshot.jobs.allSatisfy { if case .completed = $0.state { true } else { false } })
    }

    @Test func differentBooksRunInParallelUpToTheCap() async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        let inFlight = Locked((now: 0, peak: 0))
        downloader.handler.withLock {
            $0 = { _, destination in
                inFlight.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                await gate.wait()
                inFlight.withLock { $0.now -= 1 }
                try Data().write(to: destination)
            }
        }
        let (queue, _) = try await makeQueue(maximumConcurrentBooks: 3)
        try await queue.enqueue(books(5), kind: .download, exportDestination: nil)
        try await waitUntil { inFlight.current.now == 3 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(inFlight.current.peak == 3)
        #expect(await queue.currentSnapshot.jobs.filter { $0.state == .queued }.count == 2)
        await gate.open()
        await queue.waitUntilFinished()
        #expect(inFlight.current.peak == 3)
        #expect(downloadsContents().count == 5)
    }

    @Test func jobsCanBeAddedWhileOthersRun() async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        downloader.handler.withLock { $0 = { _, destination in await gate.wait(); try Data().write(to: destination) } }
        let (queue, _) = try await makeQueue()
        try await queue.enqueue([books(2)[0]], kind: .download, exportDestination: nil)
        try await waitUntil { downloader.downloads.current.count == 1 }
        let added = try await queue.enqueue([books(2)[1]], kind: .download, exportDestination: nil)
        #expect(added.count == 1)
        await gate.open()
        await queue.waitUntilFinished()
        let snapshot = await queue.currentSnapshot
        #expect(snapshot.jobs.count == 2)
        #expect(snapshot.jobs.allSatisfy { if case .completed = $0.state { true } else { false } })
    }

    @Test func enqueueSkipsWorkAlreadyCovered() async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        downloader.handler.withLock { $0 = { _, destination in await gate.wait(); try Data().write(to: destination) } }
        let (queue, _) = try await makeQueue()
        let book1 = books(2)[0], book2 = books(2)[1]
        #expect(try await queue.enqueue([book1], kind: .download, exportDestination: nil).count == 1)
        // Same kind again: skipped.
        #expect(try await queue.enqueue([book1], kind: .download, exportDestination: nil).isEmpty)
        // An export after a download of the same book is new work.
        #expect(try await queue.enqueue([book1], kind: .export, exportDestination: destination.url).count == 1)
        // A download of a book with a pending export is covered by the export.
        #expect(try await queue.enqueue([book2], kind: .export, exportDestination: destination.url).count == 1)
        #expect(try await queue.enqueue([book2], kind: .download, exportDestination: nil).isEmpty)
        await gate.open()
        await queue.waitUntilFinished()
        #expect(await queue.currentSnapshot.jobs.map(\.kind) == [.download, .export, .export])
    }

    // MARK: Failures

    @Test func failureContinuesWithNextBookAndKeepsCompletedExports() async throws {
        defer { cleanUp() }
        api.licenseHandler.withLock {
            $0 = { asin, _ in
                if asin == "B000000002" { throw ExporterError.unsupportedDRM(asin: asin, drmType: "Widevine") }
                return Fixtures.license(asin: asin)
            }
        }
        let snapshot = try await runToCompletion(books(3))
        #expect(snapshot.jobs[0].state == .completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b")))
        #expect(snapshot.jobs[1].state == .failed("Book 2: This title uses unsupported DRM (Widevine)."))
        #expect(snapshot.jobs[2].state == .completed(destination.url.appendingPathComponent("Book 3 [B000000003].m4b")))
        #expect(destination.contents() == ["Book 1 [B000000001].m4b", "Book 3 [B000000003].m4b"])
    }

    @Test(arguments: [ExportJob.Kind.download, .export])
    func downloadFailureKeepsTheBytesForTheNextDownload(kind: ExportJob.Kind) async throws {
        defer { cleanUp() }
        downloader.handler.withLock {
            $0 = { _, destination in
                try Data("partial".utf8).write(to: destination)
                throw ExporterError.download("HTTP 500")
            }
        }
        let snapshot = try await runToCompletion(books(1), kind: kind)
        #expect(snapshot.jobs[0].state == .failed("Book 1: Download failed: HTTP 500"))
        #expect(downloadsContents() == [".B000000001.download.partial"])
        #expect(manifestContents() == ["B000000001.partial"])
        let record = try #require(downloads.partialDownload(for: "B000000001"))
        #expect(record.customerID == Fixtures.session().customerID)
        #expect(record.checkpoint == DownloadCheckpoint(
            expectedLength: downloader.expectedLength, validator: MockDownloader.validator, committedLength: 7
        ))
        #expect(destination.contents().isEmpty)
        #expect(converter.requests.current.isEmpty)
    }

    @Test func nextDownloadContinuesTheKeptBytesWithAFreshLicense() async throws {
        defer { cleanUp() }
        downloader.handler.withLock {
            $0 = { _, destination in
                try Data("partial".utf8).write(to: destination)
                throw ExporterError.download("HTTP 500")
            }
        }
        let (queue, _) = try await makeQueue()
        try await queue.enqueue(books(1), kind: .download, exportDestination: nil)
        await queue.waitUntilFinished()
        downloader.handler.withLock { $0 = { _, destination in try Data("encrypted".utf8).write(to: destination) } }

        try await queue.enqueue(books(1), kind: .download, exportDestination: nil)
        await queue.waitUntilFinished()

        #expect(await queue.currentSnapshot.jobs[0].state == .completed(downloads.folder.appendingPathComponent("Book 1 [B000000001].aaxc")))
        #expect(downloader.resumes.current.first! == nil)
        #expect(downloader.resumes.current.last! == ResumePoint(
            committedLength: 7, expectedLength: downloader.expectedLength, validator: MockDownloader.validator
        ))
        #expect(api.requestedLicenses.current == ["B000000001", "B000000001"])
        #expect(downloadsContents() == ["Book 1 [B000000001].aaxc"])
        #expect(manifestContents() == ["B000000001.json"])
    }

    @Test func anotherAccountsBytesAreDiscarded() async throws {
        defer { cleanUp() }
        try downloads.ensureFolder()
        try Data("theirs".utf8).write(to: downloads.partialFileURL(for: "B000000001"))
        try downloads.writePartialDownload(PartialDownload(
            book: books(1)[0], customerID: "amzn1.account.SOMEONE.ELSE", fileExtension: "aaxc",
            checkpoint: DownloadCheckpoint(expectedLength: 9, validator: .none, committedLength: 6), updatedAt: Fixtures.referenceDate
        ))
        let snapshot = try await runToCompletion(books(1), kind: .download)
        #expect(snapshot.jobs[0].state == .completed(downloads.folder.appendingPathComponent("Book 1 [B000000001].aaxc")))
        #expect(downloader.resumes.current.first! == nil)
        #expect(try Data(contentsOf: downloads.folder.appendingPathComponent("Book 1 [B000000001].aaxc")) == Data("encrypted".utf8))
        #expect(manifestContents() == ["B000000001.json"])
    }

    @Test(arguments: [ExportJob.Kind.download, .export])
    func suspendDuringDownloadKeepsTheBytes(kind: ExportJob.Kind) async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        downloader.handler.withLock {
            $0 = { _, destination in
                try Data("partial".utf8).write(to: destination)
                await gate.wait()
                throw ExporterError.cancelled
            }
        }
        let (queue, _) = try await makeQueue()
        try await queue.enqueue(books(1) + [Fixtures.book("B000000002", title: "Book 2")], kind: kind, exportDestination: destination.url)
        try await waitUntil { downloader.downloads.current.count == 1 }
        await queue.suspend()
        await gate.open()
        await queue.waitUntilFinished()
        #expect(await queue.currentSnapshot.jobs.map(\.state) == [.cancelled, .cancelled])
        #expect(downloadsContents() == [".B000000001.download.partial"])
        #expect(manifestContents() == ["B000000001.partial"])
        #expect(destination.contents().isEmpty)
    }

    @Test func conversionFailureRemovesPartialOutputButKeepsDownload() async throws {
        defer { cleanUp() }
        converter.handler.withLock {
            $0 = { request in
                try Data("half".utf8).write(to: request.output)
                throw ExporterError.conversion("bad packet")
            }
        }
        let snapshot = try await runToCompletion(books(1))
        #expect(snapshot.jobs[0].state == .failed("Book 1: Conversion failed: bad packet"))
        #expect(destination.contents().isEmpty)
        #expect(downloadsContents() == ["Book 1 [B000000001].aaxc"])
    }

    @Test func converterWithoutOutputFails() async throws {
        defer { cleanUp() }
        converter.handler.withLock { $0 = { _ in } }
        let snapshot = try await runToCompletion(books(1))
        #expect(snapshot.jobs[0].state == .failed("Book 1: Conversion failed: The converter did not produce an output file."))
    }

    @Test func deniedLicenseIsTitleSpecific() async throws {
        defer { cleanUp() }
        api.licenseHandler.withLock { $0 = { asin, _ in throw ExporterError.licenseDenied(asin: asin, reason: "not owned") } }
        let snapshot = try await runToCompletion(books(1))
        #expect(snapshot.jobs[0].state == .failed("Book 1: The download license was denied: not owned"))
        #expect(downloader.downloads.current.isEmpty)
    }

    // MARK: Cancellation

    @Test func cancelStopsCurrentAndQueuedBooksButKeepsCompleted() async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        let started = Locked(false)
        converter.handler.withLock {
            $0 = { request in
                if request.metadata.asin == "B000000002" {
                    try Data("partial".utf8).write(to: request.output)
                    started.withLock { $0 = true }
                    await gate.wait()
                    try Task.checkCancellation()
                }
                try Data("m4b".utf8).write(to: request.output)
            }
        }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(3), destination: destination.url)
        try await waitUntil { started.current }
        await queue.cancel()
        await gate.open()
        await queue.waitUntilFinished()

        let snapshot = await queue.currentSnapshot
        #expect(snapshot.jobs.map(\.state) == [
            .completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b")), .cancelled, .cancelled,
        ])
        #expect(destination.contents() == ["Book 1 [B000000001].m4b"])
        // Finished downloads are kept, including the one whose conversion was cancelled.
        #expect(downloadsContents() == ["Book 1 [B000000001].aaxc", "Book 2 [B000000002].aaxc"])
        #expect(api.requestedLicenses.current == ["B000000001", "B000000002"])
    }

    @Test(arguments: [ExportJob.Kind.download, .export])
    func cancelDuringDownloadRemovesThePartial(kind: ExportJob.Kind) async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        downloader.handler.withLock {
            $0 = { _, destination in
                try Data("partial".utf8).write(to: destination)
                await gate.wait()
                throw ExporterError.cancelled
            }
        }
        let (queue, _) = try await makeQueue()
        try await queue.enqueue(books(1), kind: kind, exportDestination: destination.url)
        try await waitUntil { downloader.downloads.current.count == 1 }
        await queue.cancel()
        await gate.open()
        await queue.waitUntilFinished()
        #expect(await queue.currentSnapshot.jobs[0].state == .cancelled)
        #expect(downloadsContents().isEmpty)
        #expect(manifestContents().isEmpty)
        #expect(destination.contents().isEmpty)
    }

    @Test func cancellingRunningJobContinuesWithTheRest() async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        let started = Locked(false)
        converter.handler.withLock {
            $0 = { request in
                if request.metadata.asin == "B000000002" {
                    try Data("partial".utf8).write(to: request.output)
                    started.withLock { $0 = true }
                    await gate.wait()
                    try Task.checkCancellation()
                }
                try Data("m4b".utf8).write(to: request.output)
            }
        }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(3), destination: destination.url)
        try await waitUntil { started.current }
        await queue.cancel(await queue.currentSnapshot.jobs[1].id)
        await gate.open()
        await queue.waitUntilFinished()

        let snapshot = await queue.currentSnapshot
        #expect(snapshot.jobs.map(\.state) == [
            .completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b")),
            .cancelled,
            .completed(destination.url.appendingPathComponent("Book 3 [B000000003].m4b")),
        ])
        #expect(destination.contents() == ["Book 1 [B000000001].m4b", "Book 3 [B000000003].m4b"])
        #expect(!downloadsContents().contains(where: ExportFileNaming.isPartial))
        #expect(!snapshot.isRunning)
    }

    @Test func cancellingQueuedJobSkipsIt() async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        let started = Locked(false)
        converter.handler.withLock {
            $0 = { request in
                if request.metadata.asin == "B000000001" {
                    started.withLock { $0 = true }
                    await gate.wait()
                }
                try Data("m4b".utf8).write(to: request.output)
            }
        }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(3), destination: destination.url)
        try await waitUntil { started.current }
        await queue.cancel(await queue.currentSnapshot.jobs[1].id)
        #expect(await queue.currentSnapshot.jobs[1].state == .cancelled)
        await gate.open()
        await queue.waitUntilFinished()

        let snapshot = await queue.currentSnapshot
        #expect(snapshot.jobs.map(\.state) == [
            .completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b")),
            .cancelled,
            .completed(destination.url.appendingPathComponent("Book 3 [B000000003].m4b")),
        ])
        #expect(api.requestedLicenses.current == ["B000000001", "B000000003"])
    }

    @Test func cancellingFinishedOrUnknownJobChangesNothing() async throws {
        defer { cleanUp() }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(1), destination: destination.url)
        await queue.waitUntilFinished()
        let before = await queue.currentSnapshot
        await queue.cancel(before.jobs[0].id)
        await queue.cancel(UUID())
        #expect(await queue.currentSnapshot == before)
    }

    @Test func clearForgetsFinishedJobsButNotRunningOnes() async throws {
        defer { cleanUp() }
        let gate = AsyncGate()
        converter.handler.withLock { $0 = { request in await gate.wait(); try Data("m4b".utf8).write(to: request.output) } }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(1), destination: destination.url)
        await queue.clear()
        #expect(await queue.currentSnapshot.jobs.count == 1)
        await gate.open()
        await queue.waitUntilFinished()
        await queue.clear()
        #expect(await queue.currentSnapshot == ExportQueue.Snapshot())
        #expect(destination.contents() == ["Book 1 [B000000001].m4b"])
    }

    // MARK: Authentication

    @Test func pausesForAuthenticationAndResumesAfterSignIn() async throws {
        defer { cleanUp() }
        let signedInAgain = Locked(false)
        api.licenseHandler.withLock {
            $0 = { asin, session in
                guard session.accessToken == "fresh" else { throw ExporterError.authenticationRequired }
                return Fixtures.license(asin: asin)
            }
        }
        api.refreshHandler.withLock {
            $0 = { _ in
                if signedInAgain.current { return Fixtures.session(accessToken: "fresh") }
                throw ExporterError.authenticationRequired
            }
        }
        api.registerHandler.withLock { $0 = { _, _ in Fixtures.session(accessToken: "fresh") } }

        let (queue, auth) = try await makeQueue()
        try await queue.start(books(2), destination: destination.url)
        try await waitUntil { await queue.currentSnapshot.isWaitingForAuthentication }
        #expect(await queue.currentSnapshot.jobs.map(\.state) == [.waitingForAuthentication, .queued])
        #expect(await auth.state == .reauthenticationRequired(.us))

        // The user signs in again; the coordinator now holds a working session.
        signedInAgain.withLock { $0 = true }
        _ = try await auth.beginLogin(marketplace: .us)
        _ = try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        await queue.resumeAfterAuthentication()
        await queue.waitUntilFinished()

        let snapshot = await queue.currentSnapshot
        #expect(snapshot.jobs.allSatisfy { if case .completed = $0.state { true } else { false } })
        #expect(!snapshot.isWaitingForAuthentication)
    }

    @Test func severalJobsPauseForAuthenticationAndAllResume() async throws {
        defer { cleanUp() }
        let signedInAgain = Locked(false)
        api.licenseHandler.withLock {
            $0 = { asin, session in
                guard session.accessToken == "fresh" else { throw ExporterError.authenticationRequired }
                return Fixtures.license(asin: asin)
            }
        }
        api.refreshHandler.withLock {
            $0 = { _ in
                if signedInAgain.current { return Fixtures.session(accessToken: "fresh") }
                throw ExporterError.authenticationRequired
            }
        }
        api.registerHandler.withLock { $0 = { _, _ in Fixtures.session(accessToken: "fresh") } }

        let (queue, auth) = try await makeQueue(maximumConcurrentBooks: 3)
        try await queue.enqueue(books(2), kind: .download, exportDestination: nil)
        try await waitUntil { await queue.currentSnapshot.jobs.allSatisfy { $0.state == .waitingForAuthentication } }
        #expect(await queue.currentSnapshot.isWaitingForAuthentication)

        signedInAgain.withLock { $0 = true }
        _ = try await auth.beginLogin(marketplace: .us)
        _ = try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        await queue.resumeAfterAuthentication()
        await queue.waitUntilFinished()
        #expect(await queue.currentSnapshot.jobs.allSatisfy { if case .completed = $0.state { true } else { false } })
        #expect(downloadsContents().count == 2)
    }

    @Test func pausedExportOfKeptDownloadResumes() async throws {
        defer { cleanUp() }
        // No manifest, so the export needs a license and pauses for sign-in.
        _ = try keepDownload(books(1)[0], withManifest: false)
        api.licenseHandler.withLock {
            $0 = { asin, session in
                guard session.accessToken == "fresh" else { throw ExporterError.authenticationRequired }
                return Fixtures.license(asin: asin)
            }
        }
        api.refreshHandler.withLock { $0 = { _ in throw ExporterError.authenticationRequired } }
        api.registerHandler.withLock { $0 = { _, _ in Fixtures.session(accessToken: "fresh") } }
        let (queue, auth) = try await makeQueue()
        try await queue.start(books(1), destination: destination.url)
        try await waitUntil { await queue.currentSnapshot.isWaitingForAuthentication }
        _ = try await auth.beginLogin(marketplace: .us)
        _ = try await auth.completeLogin(callbackURL: Fixtures.callbackURL())
        await queue.resumeAfterAuthentication()
        await queue.waitUntilFinished()
        #expect(downloader.downloads.current.isEmpty)
        #expect(await queue.currentSnapshot.jobs[0].state == .completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b")))
    }

    @Test func cancelWhileWaitingForAuthentication() async throws {
        defer { cleanUp() }
        api.licenseHandler.withLock { $0 = { _, _ in throw ExporterError.authenticationRequired } }
        api.refreshHandler.withLock { $0 = { _ in throw ExporterError.authenticationRequired } }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(2), destination: destination.url)
        try await waitUntil { await queue.currentSnapshot.isWaitingForAuthentication }
        await queue.cancel()
        await queue.waitUntilFinished()
        #expect(await queue.currentSnapshot.jobs.map(\.state) == [.cancelled, .cancelled])
        #expect(await !queue.currentSnapshot.isRunning)
    }

    @Test func resumingWhileStillSignedOutWaitsAgain() async throws {
        defer { cleanUp() }
        api.licenseHandler.withLock { $0 = { _, _ in throw ExporterError.authenticationRequired } }
        api.refreshHandler.withLock { $0 = { _ in throw ExporterError.authenticationRequired } }
        let (queue, _) = try await makeQueue()
        try await queue.start(books(1), destination: destination.url)
        try await waitUntil { await queue.currentSnapshot.isWaitingForAuthentication }
        await queue.resumeAfterAuthentication()
        try await waitUntil { await queue.currentSnapshot.jobs[0].state == .waitingForAuthentication }
        try await waitUntil { await queue.currentSnapshot.isWaitingForAuthentication }
        await queue.cancel()
        await queue.waitUntilFinished()
        #expect(await queue.currentSnapshot.jobs[0].state == .cancelled)
    }

    // MARK: Enqueue validation

    @Test func rejectsInvalidEnqueues() async throws {
        defer { cleanUp() }
        let (queue, _) = try await makeQueue()
        await #expect(throws: ExportQueue.StartError.nothingToExport) { try await queue.start([], destination: destination.url) }
        let missing = destination.url.appendingPathComponent("missing")
        await #expect(throws: ExportQueue.StartError.destinationUnavailable(missing.path)) {
            try await queue.start(books(1), destination: missing)
        }
        try await queue.start(books(1), destination: destination.url)
        await queue.waitUntilFinished()
        try await queue.start(books(1), destination: destination.url) // a finished queue can start again
        await queue.waitUntilFinished()
    }

    @Test func createsMissingDownloadFolder() async throws {
        defer { cleanUp() }
        #expect(!FileManager.default.fileExists(atPath: downloads.folder.path))
        _ = try await runToCompletion(books(1), kind: .download)
        #expect(downloadsContents() == ["Book 1 [B000000001].aaxc"])
    }

    @Test func uncreatableDownloadFolderIsReported() async throws {
        defer { cleanUp() }
        // A regular file where the folder should be.
        let blocker = work.url.appendingPathComponent("NotAFolder")
        try Data().write(to: blocker)
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        let queue = ExportQueue(
            auth: auth, api: api, downloader: downloader, converter: converter,
            downloads: LocalDownloads(folder: blocker, manifestFolder: work.url.appendingPathComponent("M"))
        )
        await #expect(throws: ExportQueue.StartError.destinationUnavailable(blocker.path)) {
            try await queue.enqueue(books(1), kind: .download, exportDestination: nil)
        }
        #expect(await queue.currentSnapshot.jobs.isEmpty)
    }
}
