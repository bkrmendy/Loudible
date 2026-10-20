import Testing
import LoudibleScheduling

@Suite struct KeyedSchedulerPauseTests {
    @Test func pauseKeepsReservationsAndPendingOrder() {
        var queue = KeyedScheduler<Int, Int>(maximumConcurrent: 2)
        queue.enqueue(id: 1, key: 0)
        #expect(queue.reserveReady().map(\.id) == [1])
        queue.setPaused(true)
        queue.enqueue(id: 2, key: 0)
        queue.enqueue(id: 3, key: 1)
        #expect(queue.reserveReady().isEmpty)
        #expect(!queue.isIdle)
        let result1 = queue.removePending(id: 3)
        #expect(result1)
        queue.enqueue(id: 4, key: 1)
        queue.setPaused(false)
        #expect(queue.reserveReady().map(\.id) == [4])
        queue.finish(id: 1)
        #expect(queue.reserveReady().map(\.id) == [2])
    }
}
