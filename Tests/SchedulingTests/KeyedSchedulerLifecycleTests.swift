import Testing
import LoudibleScheduling

@Suite struct KeyedSchedulerLifecycleTests {
    @Test func removalDoesNotReleaseActiveWork() {
        var queue = KeyedScheduler<Int, Int>(maximumConcurrent: 1)
        #expect(queue.isIdle)
        let result1 = queue.enqueue(id: 1, key: 0)
        #expect(result1)
        let result2 = queue.enqueue(id: 1, key: 1)
        #expect(!result2)
        #expect(queue.reserveReady().map(\.id) == [1])
        let result3 = queue.enqueue(id: 1, key: 1)
        #expect(!result3)
        queue.enqueue(id: 2, key: 0)
        queue.enqueue(id: 3, key: 1)
        let result4 = queue.removePending(id: 1)
        #expect(!result4)
        let result5 = queue.removePending(id: 99)
        #expect(!result5)
        let result6 = queue.removePending(id: 2)
        #expect(result6)
        #expect(queue.removeAllPending().map(\.id) == [3])
        #expect(!queue.isIdle)
        queue.finish(id: 99)
        #expect(!queue.isIdle)
        queue.finish(id: 1)
        #expect(queue.isIdle)
        queue.enqueue(id: 4, key: 0)
        #expect(queue.reserveReady().map(\.id) == [4])
    }
}
