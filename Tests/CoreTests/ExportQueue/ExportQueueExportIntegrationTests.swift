import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct ExportQueueExportIntegrationTests: ExportQueueTestCase {
    let fixture: ExportQueueTestFixture
    init() throws { fixture = try ExportQueueTestFixture() }

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
        #expect(request.input.standardizedFileURL == downloads.folder.appendingPathComponent("Book 1 [B000000001].aaxc")
            .standardizedFileURL)
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
        let snapshot = try await runToCompletion(books(1) + books(1).map { _ in
            Fixtures.book("B000000001", title: "dup") })
        #expect(snapshot.jobs.count == 1) // duplicate ASINs are exported once
        #expect(destination.contents() == ["Book 1 [B000000001] (2).m4b", "Book 1 [B000000001].m4b"])
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
    }

    @Test func reportsPhasesAndProgress() async throws {
        defer { cleanUp() }
        let downloadGate = AsyncGate(), convertGate = AsyncGate()
        downloader.handler
            .withLock { $0 = { _, destination in await downloadGate.wait(); try Data().write(to: destination) } }
        converter.handler
            .withLock { $0 = { request in await convertGate.wait(); try Data().write(to: request.output) } }
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
}
