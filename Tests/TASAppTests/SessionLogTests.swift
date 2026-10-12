import XCTest
@testable import TASApp

final class SessionLogTests: XCTestCase {
    func testRetentionIsBoundedNewestFirstWithStableIDsAndReset() {
        var log = SessionLog(capacity: 3)
        log.append("one")
        let first = log.entries[0].id
        log.append("two")
        XCTAssertEqual(log.entries[1].id, first)
        log.append("two")
        XCTAssertEqual(Set(log.entries.map(\.id)).count, 3)
        log.append("four")
        XCTAssertEqual(log.entries.map(\.message), ["four", "two", "two"])
        XCTAssertEqual(log.discardedCount, 1)
        for _ in 0..<1000 { log.append("repeat") }
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.discardedCount, 1001)
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.discardedCount, 0)
    }
    func testHugeMessageIsBoundedAndMarkedAsTruncated() {
        var log = SessionLog()
        log.append(String(repeating: "界", count: 10000))
        XCTAssertLessThanOrEqual(log.entries[0].message.count, SessionLog.messageLimit)
        XCTAssertTrue(log.entries[0].truncated)
        XCTAssertEqual(log.capacity, 500)
    }
}
