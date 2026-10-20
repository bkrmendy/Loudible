import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct ExportQueueDownloadIntegrationTests: ExportQueueTestCase {
    let fixture: ExportQueueTestFixture
    init() throws { fixture = try ExportQueueTestFixture() }

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
                ContentLicense(
                    asin: asin,
                    decryption: .aax(activationBytes: Data([1, 2, 3, 4])),
                    downloadURL: URL(string: "https://cdn.example.invalid/x.aax")!,
                    chapters: [])
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
        #expect(snapshot.jobs
            .map(\.state) == [.completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b"))])
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
}
