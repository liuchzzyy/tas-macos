#if os(macOS)
import Foundation

/// Bounded in-memory session history; cleared on lock. IDs survive prepends.
struct SessionLog {
    struct Entry: Identifiable {
        let id = UUID()
        let message: String
        let truncated: Bool
    }
    static let messageLimit = 4096
    let capacity: Int
    private(set) var entries: [Entry] = []
    private(set) var discardedCount = 0
    init(capacity: Int = 500) { self.capacity = max(1, capacity) }
    mutating func append(_ message: String) {
        let prefix = String(message.prefix(Self.messageLimit))
        entries.insert(Entry(message: prefix, truncated: prefix.endIndex != message.endIndex), at: 0)
        if entries.count > capacity {
            discardedCount += entries.count - capacity
            entries.removeLast(entries.count - capacity)
        }
    }
    mutating func clear() { entries.removeAll(); discardedCount = 0 }
}
#endif
