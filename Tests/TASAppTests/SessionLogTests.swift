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
    func testMultiByteGraphemesAreBoundedByBytesWithoutSplitting() {
        var log = SessionLog()
        let cluster = "👩‍👩‍👧‍👦"
        log.append(String(repeating: cluster, count: 4000))
        let entry = log.entries[0]
        XCTAssertLessThanOrEqual(entry.message.utf8.count, SessionLog.byteLimit)
        XCTAssertLessThanOrEqual(entry.message.count, SessionLog.messageLimit)
        XCTAssertTrue(entry.truncated)
        XCTAssertEqual(String(entry.message.prefix(1)), cluster, "Truncation must not split a grapheme cluster")
    }
    func testMessagesWithinBothLimitsAreNotMarkedTruncated() {
        var log = SessionLog()
        log.append("")
        XCTAssertEqual(log.entries[0].message, "")
        XCTAssertFalse(log.entries[0].truncated)
        log.append(String(repeating: "a", count: SessionLog.messageLimit))
        XCTAssertEqual(log.entries[0].message.count, SessionLog.messageLimit)
        XCTAssertFalse(log.entries[0].truncated)
        log.append(String(repeating: "a", count: SessionLog.messageLimit + 1))
        XCTAssertTrue(log.entries[0].truncated)
    }
}
