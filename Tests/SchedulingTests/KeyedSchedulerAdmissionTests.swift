import Testing
import LoudibleScheduling

@Suite struct KeyedSchedulerAdmissionTests {
    @Test func keysSerializeWithoutBlockingOtherKeys() {
        var queue = KeyedScheduler<Int, String>(maximumConcurrent: 3)
        queue.enqueue(id: 1, key: "a")
        queue.enqueue(id: 2, key: "a")
        queue.enqueue(id: 3, key: "b")
        queue.enqueue(id: 4, key: "c")
        #expect(queue.reserveReady().map(\.id) == [1, 3, 4])
        #expect(queue.reserveReady().isEmpty)
        queue.finish(id: 1)
        #expect(queue.reserveReady().map(\.id) == [2])
    }

    @Test(arguments: [-1, 0, 1, 3]) func capacityIsBounded(_ limit: Int) {
        var queue = KeyedScheduler<Int, Int>(maximumConcurrent: limit)
        for id in 0..<5 { queue.enqueue(id: id, key: id) }
        #expect(queue.reserveReady().map(\.id) == Array(0..<max(1, limit)))
        #expect(queue.reserveReady().isEmpty)
    }
}
