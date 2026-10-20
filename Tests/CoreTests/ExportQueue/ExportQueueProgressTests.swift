import Foundation
import Testing
@testable import LoudibleCore
import TestSupport

@Suite struct ExportQueueProgressTests {
    private func setup() -> (ExportQueueState, UUID) {
        let job = ExportJob(book: Fixtures.book("B000000001"))
        var state = ExportQueueState()
        state.snapshot.jobs = [job]
        state.report(job.id, event: .phase(.downloading))
        let invocation = UUID()
        state.report(job.id, event: .beginDownload(invocation))
        return (state, invocation)
    }

    private func progress(_ attempt: Int, _ bytes: Int64) -> DownloadProgress {
        DownloadProgress(attempt: attempt, transferred: TransferProgress(bytesReceived: bytes, bytesExpected: 100))
    }

    @Test func fallbackResetsBytesAndIgnoresOlderAttempts() {
        var (state, invocation) = setup()
        let id = state.snapshot.jobs[0].id
        state.report(id, event: .download(invocation, progress(0, 80)))
        #expect(state.snapshot.jobs[0].transferred?.bytesReceived == 80)
        state.report(id, event: .download(invocation, progress(1, 0)))
        #expect(state.snapshot.jobs[0].state == .running(.downloading, progress: 0))
        #expect(state.snapshot.jobs[0].transferred?.bytesReceived == 0)
        state.report(id, event: .download(invocation, progress(1, 10)))
        state.report(id, event: .download(invocation, progress(0, 95)))
        state.report(id, event: .download(invocation, progress(1, 5)))
        #expect(state.snapshot.jobs[0].state == .running(.downloading, progress: 0.1))
        #expect(state.snapshot.jobs[0].transferred?.bytesReceived == 10)
        #expect(state.snapshot.jobs[0].firstPhase == .downloading)
    }

    @Test func completedErrorBodyDoesNotStickAtFullProgress() {
        var (state, invocation) = setup()
        let id = state.snapshot.jobs[0].id
        state.report(id, event: .download(invocation, progress(0, 100)))
        // A callback for the new attempt can arrive before its initial zero event.
        state.report(id, event: .download(invocation, progress(1, 10)))
        state.report(id, event: .download(invocation, progress(1, 0)))
        #expect(state.snapshot.jobs[0].state == .running(.downloading, progress: 0.1))
    }

    @Test func endedInvocationsAndFinishedJobsRejectCallbacks() {
        var (state, invocation) = setup()
        let id = state.snapshot.jobs[0].id
        state.report(id, event: .endDownload(invocation))
        state.report(id, event: .download(invocation, progress(1, 90)))
        #expect(state.snapshot.jobs[0].transferred == nil)
        let next = UUID()
        state.report(id, event: .beginDownload(next))
        state.report(id, event: .download(next, progress(0, 20)))
        state.report(id, event: .download(invocation, progress(2, 100)))
        #expect(state.snapshot.jobs[0].transferred?.bytesReceived == 20)
        state.update(id, to: .cancelled)
        state.report(id, event: .download(next, progress(1, 99)))
        #expect(state.snapshot.jobs[0].state == .cancelled)
    }

    @Test func streamStartsWithCurrentSnapshotAndCoalescesUpdates() async {
        var (state, _) = setup()
        let id = state.snapshot.jobs[0].id
        let stream = state.updates(id: UUID(), onTermination: {})
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == state.snapshot)
        state.update(id, to: .failed("failure"))
        state.snapshot.isRunning = false
        #expect(await iterator.next() == state.snapshot)
    }
}
