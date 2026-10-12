import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct BookStatusTests {
    let book = Fixtures.book("B1")

    func job(_ kind: ExportJob.Kind, _ states: [ExportJob.State], asin: String = "B1") throws -> ExportJob {
        var job = ExportJob(book: Fixtures.book(asin), kind: kind)
        for state in states { try job.transition(to: state) }
        return job
    }

    func resolve(_ jobs: [ExportJob], failure: (kind: ExportJob.Kind, message: String)? = nil, downloaded: Bool = false, exported: Bool = false) -> BookStatus {
        BookStatus.resolve(asin: "B1", jobs: jobs, failure: failure, isDownloaded: downloaded, isExported: exported)
    }

    @Test func priorityRunningQueuedFailedExportedDownloaded() throws {
        let running = try job(.export, [.running(.converting, progress: 0)])
        let queued = try job(.download, [])
        #expect(resolve([queued, running], failure: (.download, "x"), downloaded: true, exported: true) == .running(.export, progress: 0))
        #expect(resolve([queued], failure: (.download, "x"), downloaded: true, exported: true) == .queued(.download))
        #expect(resolve([], failure: (.download, "x"), downloaded: true, exported: true) == .failed(.download, "x"))
        #expect(resolve([], downloaded: true, exported: true) == .exported)
        #expect(resolve([], downloaded: true) == .downloaded)
        #expect(resolve([]) == .none)
    }

    @Test func ignoresFinishedJobsAndOtherBooks() throws {
        let finished = try job(.download, [.running(.licensing, progress: 0), .failed("x")])
        let other = try job(.download, [.running(.licensing, progress: 0)], asin: "B2")
        #expect(resolve([finished, other], downloaded: true) == .downloaded)
    }

    @Test func pausedForSignInShowsAsQueued() throws {
        #expect(resolve([try job(.download, [.waitingForAuthentication])]) == .queued(.download))
    }

    func context(
        downloaded: Bool = false, exported: Bool = false, inLibrary: Bool = true,
        manifest: Bool = true, signedIn: Bool = true
    ) -> BookMenu.Context {
        BookMenu.Context(isDownloaded: downloaded, isExported: exported, isInLibrary: inLibrary, hasManifest: manifest, isSignedIn: signedIn)
    }

    func actions(jobs: [ExportJob] = [], _ context: BookMenu.Context) -> [BookAction] {
        BookMenu.items(asin: "B1", jobs: jobs, context: context).map(\.action)
    }

    func export(jobs: [ExportJob] = [], _ context: BookMenu.Context) -> BookMenuItem? {
        BookMenu.items(asin: "B1", jobs: jobs, context: context).first { $0.action == .export }
    }

    @Test func notDownloadedOffersDownloadOnly() {
        #expect(actions(context()) == [.download])
        // There is nothing to download for a book that left the library.
        #expect(actions(context(inLibrary: false)) == [])
    }

    @Test func runningOrQueuedJobsOfferCancelOnly() throws {
        let download = try job(.download, [.running(.downloading, progress: 0.3)])
        let export = try job(.export, [])
        #expect(actions(jobs: [download, export], context()) == [
            .cancel(jobID: download.id, kind: .download), .cancel(jobID: export.id, kind: .export),
        ])
    }

    @Test func downloadedOffersExportFinderAndDelete() {
        #expect(actions(context(downloaded: true)) == [.export, .showDownload, .deleteDownload])
        #expect(actions(context(downloaded: true, exported: true)) == [.export, .showDownload, .showExport, .deleteDownload])
        #expect(export(context(downloaded: true))?.isEnabled == true)
    }

    @Test func exportedWithoutDownloadOffersDownloadAndShowExport() {
        #expect(actions(context(exported: true)) == [.download, .showExport])
    }

    @Test func busyDownloadedBookDisablesExportAndHidesDelete() throws {
        let export = try job(.export, [.running(.converting, progress: 0.1)])
        let items = BookMenu.items(asin: "B1", jobs: [export], context: context(downloaded: true))
        #expect(items.map(\.action) == [.cancel(jobID: export.id, kind: .export), .export, .showDownload])
        #expect(items[1].isEnabled == false)
        #expect(items[1].disabledReason != nil)
    }

    @Test func exportIsDisabledWithAReason() {
        let notInLibrary = export(context(downloaded: true, inLibrary: false))
        #expect(notInLibrary?.isEnabled == false)
        #expect(notInLibrary?.disabledReason == "This book is no longer in your library.")

        let noKeysSignedOut = export(context(downloaded: true, manifest: false, signedIn: false))
        #expect(noKeysSignedOut?.isEnabled == false)
        #expect(noKeysSignedOut?.disabledReason?.contains("Sign in") == true)

        // Stored keys make sign-in unnecessary; a missing manifest is fine while signed in.
        #expect(export(context(downloaded: true, signedIn: false))?.isEnabled == true)
        #expect(export(context(downloaded: true, manifest: false))?.isEnabled == true)
    }
}
