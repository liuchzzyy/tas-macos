#if os(macOS)
import Foundation

/// Bounded in-memory session history; cleared on lock. IDs survive prepends.
struct SessionLog {
    struct Entry: Identifiable {
        let id = UUID()
        let message: String
        let truncated: Bool
    }
    /// Characters keep entries readable for the user; bytes bound resident
    /// memory, because one grapheme cluster can occupy many UTF-8 bytes.
    static let messageLimit = 4096
    static let byteLimit = 16 * 1024
    let capacity: Int
    private(set) var entries: [Entry] = []
    private(set) var discardedCount = 0
    init(capacity: Int = 500) { self.capacity = max(1, capacity) }
    mutating func append(_ message: String) {
        let (prefix, truncated) = Self.bounded(message)
        entries.insert(Entry(message: prefix, truncated: truncated), at: 0)
        if entries.count > capacity {
            discardedCount += entries.count - capacity
            entries.removeLast(entries.count - capacity)
        }
    }
    mutating func clear() { entries.removeAll(); discardedCount = 0 }

    /// Truncate on grapheme boundaries so no half-formed character is stored.
    private static func bounded(_ message: String) -> (String, Bool) {
        var text = ""
        var bytes = 0
        for character in message {
            guard text.count < messageLimit, bytes + String(character).utf8.count <= byteLimit else { return (text, true) }
            text.append(character)
            bytes += String(character).utf8.count
        }
        return (text, false)
    }
}
#endif
