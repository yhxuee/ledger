import Foundation

struct ExpiringCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var expiresAt: Date
        var access: UInt64
    }
    let capacity: Int
    let lifetime: TimeInterval
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    var count: Int { entries.count }

    init(capacity: Int, lifetime: TimeInterval) {
        self.capacity = max(0, capacity)
        self.lifetime = max(0, lifetime)
    }

    subscript(key: Key) -> Value? {
        mutating get { value(for: key, now: .now) }
        set { insert(newValue, for: key, now: .now) }
    }

    mutating func value(for key: Key, now: Date) -> Value? {
        guard var entry = entries[key] else { return nil }
        guard entry.expiresAt > now else { entries[key] = nil; return nil }
        clock &+= 1
        entry.access = clock
        entries[key] = entry
        return entry.value
    }

    mutating func insert(_ value: Value?, for key: Key, now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
        guard let value, capacity > 0 else { entries[key] = nil; return }
        clock &+= 1
        entries[key] = Entry(value: value, expiresAt: now.addingTimeInterval(lifetime), access: clock)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key { entries[oldest] = nil }
    }

    mutating func removeAll() { entries.removeAll(keepingCapacity: false) }
}
