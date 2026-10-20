/// Pure admission policy. The owner runs work and releases reservations after cleanup.
package struct KeyedScheduler<ID: Hashable & Sendable, Key: Hashable & Sendable>: Sendable {
    package struct Entry: Sendable, Equatable {
        package let id: ID
        package let key: Key
    }

    private let maximumConcurrent: Int
    private var pending: [Entry] = []
    private var active: [ID: Key] = [:]
    private var paused = false

    package init(maximumConcurrent: Int) { self.maximumConcurrent = max(1, maximumConcurrent) }

    package var isIdle: Bool { pending.isEmpty && active.isEmpty }

    @discardableResult
    package mutating func enqueue(id: ID, key: Key) -> Bool {
        guard active[id] == nil, !pending.contains(where: { $0.id == id }) else { return false }
        pending.append(Entry(id: id, key: key))
        return true
    }

    package mutating func reserveReady() -> [Entry] {
        guard !paused else { return [] }
        var keys = Set(active.values)
        var ready: [Entry] = []
        pending.removeAll { entry in
            guard active.count < maximumConcurrent, keys.insert(entry.key).inserted else { return false }
            active[entry.id] = entry.key
            ready.append(entry)
            return true
        }
        return ready
    }

    package mutating func removePending(id: ID) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        pending.remove(at: index)
        return true
    }

    package mutating func removeAllPending() -> [Entry] {
        let removed = pending
        pending.removeAll()
        return removed
    }

    package mutating func finish(id: ID) { active[id] = nil }
    package mutating func setPaused(_ paused: Bool) { self.paused = paused }
}
