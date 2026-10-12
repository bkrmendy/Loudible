import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct ExportJobTests {
    private func job() -> ExportJob { ExportJob(book: Fixtures.book("B000000001")) }

    @Test func happyPathAdvancesThroughPhases() throws {
        var job = job()
        #expect(job.state == .queued)
        try job.transition(to: .running(.licensing, progress: 0))
        try job.transition(to: .running(.downloading, progress: 0))
        try job.transition(to: .running(.downloading, progress: 0.5))
        try job.transition(to: .running(.converting, progress: 0.2))
        try job.transition(to: .running(.finalizing, progress: 0))
        let output = URL(fileURLWithPath: "/tmp/out.m4b")
        try job.transition(to: .completed(output))
        #expect(job.state == .completed(output))
        #expect(job.fractionCompleted == 1)
    }

    @Test func phasesAndProgressNeverGoBackwards() throws {
        var job = job()
        try job.transition(to: .running(.licensing, progress: 0))
        try job.transition(to: .running(.converting, progress: 0.5))
        #expect(throws: ExportJob.InvalidTransition.self) { try job.transition(to: .running(.downloading, progress: 1)) }
        #expect(throws: ExportJob.InvalidTransition.self) { try job.transition(to: .running(.converting, progress: 0.4)) }
    }

    @Test func finishedStatesAreFinal() throws {
        for finished in [ExportJob.State.completed(URL(fileURLWithPath: "/x")), .failed("e"), .cancelled] {
            var job = job()
            try job.transition(to: .running(.licensing, progress: 0))
            try job.transition(to: finished)
            #expect(job.state.isFinished)
            #expect(throws: ExportJob.InvalidTransition.self) { try job.transition(to: .queued) }
            #expect(throws: ExportJob.InvalidTransition.self) { try job.transition(to: .running(.licensing, progress: 0)) }
            #expect(throws: ExportJob.InvalidTransition.self) { try job.transition(to: .cancelled) }
        }
    }

    @Test func authenticationPauseRestartsFromLicensing() throws {
        var job = job()
        try job.transition(to: .running(.licensing, progress: 0))
        try job.transition(to: .running(.downloading, progress: 0.3))
        try job.transition(to: .waitingForAuthentication)
        #expect(throws: ExportJob.InvalidTransition.self) { try job.transition(to: .running(.downloading, progress: 0)) }
        try job.transition(to: .running(.licensing, progress: 0))
        #expect(job.state == .running(.licensing, progress: 0))
    }

    @Test func queuedJobCanStartInAnyPhaseButNotComplete() throws {
        var job = job()
        #expect(throws: ExportJob.InvalidTransition.self) { try job.transition(to: .completed(URL(fileURLWithPath: "/x"))) }
        // An export of a kept download starts at converting.
        try job.transition(to: .running(.converting, progress: 0))
        #expect(job.firstPhase == .converting)
        #expect(job.fractionCompleted == 0)
        try job.transition(to: .running(.converting, progress: 0.5))
        #expect(abs(job.fractionCompleted - 0.475) < 0.0001) // 0.38 * 0.5 of the remaining 0.40
    }

    @Test func queuedJobCanBeCancelledOrPaused() throws {
        var cancelled = job()
        try cancelled.transition(to: .cancelled)
        var paused = job()
        try paused.transition(to: .waitingForAuthentication)
        try paused.transition(to: .cancelled)
        #expect(paused.state == .cancelled)
    }

    @Test func fractionCompletedIsMonotonicAcrossPhases() throws {
        var job = job()
        var last = job.fractionCompleted
        for state: ExportJob.State in [
            .running(.licensing, progress: 0), .running(.licensing, progress: 1),
            .running(.downloading, progress: 0.5), .running(.downloading, progress: 1),
            .running(.converting, progress: 0.5), .running(.finalizing, progress: 1),
        ] {
            try job.transition(to: state)
            #expect(job.fractionCompleted >= last)
            last = job.fractionCompleted
        }
        #expect(last <= 1)
    }

    @Test func downloadWeightsDownloadingMost() throws {
        var job = ExportJob(book: Fixtures.book("B000000001"), kind: .download)
        try job.transition(to: .running(.licensing, progress: 1))
        #expect(abs(job.fractionCompleted - 0.02) < 0.0001)
        try job.transition(to: .running(.downloading, progress: 0.5))
        #expect(abs(job.fractionCompleted - 0.50) < 0.0001)
        try job.transition(to: .running(.finalizing, progress: 0))
        #expect(abs(job.fractionCompleted - 0.98) < 0.0001)
    }

    @Test func jobsOfOneBookHaveDistinctIDs() {
        let book = Fixtures.book("B000000001")
        let download = ExportJob(book: book, kind: .download)
        let export = ExportJob(book: book, kind: .export)
        #expect(download.id != export.id)
        #expect(ExportJob(book: book).kind == .export)
    }
}
