import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct ExportQueueAuthenticationTests: ExportQueueTestCase {
    let fixture: ExportQueueTestFixture
    init() throws { fixture = try ExportQueueTestFixture() }

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
        #expect(await queue.currentSnapshot.jobs[0]
            .state == .completed(destination.url.appendingPathComponent("Book 1 [B000000001].m4b")))
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
}
