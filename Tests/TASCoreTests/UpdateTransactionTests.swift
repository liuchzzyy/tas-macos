import XCTest
@testable import TASCore

final class UpdateTransactionTests: XCTestCase {
    private func fixture() throws -> (target: URL, staging: URL, backup: URL, failed: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tas-transaction-\(UUID().uuidString)")
        try Paths.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("TAS.app")
        let staging = root.appendingPathComponent("staging.app")
        for (url, value) in [(target, "old"), (staging, "new")] {
            try Paths.privateDirectory(url)
            try Data(value.utf8).write(to: url.appendingPathComponent("version"))
        }
        return (target, staging, root.appendingPathComponent("backup.app"), root.appendingPathComponent("failed.app"))
    }
    private func version(_ app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8)
    }

    func testInstallVerificationFailureRollsBack() throws {
        let f = try fixture()
        XCTAssertThrowsError(try UpdateInstallationTransaction.install(staging: f.staging, target: f.target, backup: f.backup, failed: f.failed,
            verify: { _ in throw TASError("bad signature") },
            launch: { _ in XCTFail("Must not launch unverified app") },
            writeReport: { XCTFail("Must not report success") }))
        XCTAssertEqual(try version(f.target), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.path))
    }

    func testLaunchFailureRollsBack() throws {
        let f = try fixture()
        XCTAssertThrowsError(try UpdateInstallationTransaction.install(staging: f.staging, target: f.target, backup: f.backup, failed: f.failed,
            verify: { _ in }, launch: { _ in throw TASError("launch failed") }, writeReport: { XCTFail("Must not report success") }))
        XCTAssertEqual(try version(f.target), "old")
    }

    func testRollbackFailurePreservesOnlyBackup() throws {
        let f = try fixture()
        XCTAssertThrowsError(try UpdateInstallationTransaction.install(staging: f.staging, target: f.target, backup: f.backup, failed: f.failed,
            verify: { _ in throw TASError("verify failed") }, launch: { _ in }, writeReport: {},
            move: { source, target in
                if source == f.backup { throw TASError("restore denied") }
                try FileManager.default.moveItem(at: source, to: target)
            })) { error in XCTAssertTrue(error.localizedDescription.contains(f.backup.path)) }
        XCTAssertEqual(try version(f.backup), "old")
        XCTAssertEqual(try version(f.failed), "new")
    }

    func testFailedNewBundleCannotBeMovedPreservesBothCopies() throws {
        let f = try fixture()
        XCTAssertThrowsError(try UpdateInstallationTransaction.install(staging: f.staging, target: f.target, backup: f.backup, failed: f.failed,
            verify: { _ in throw TASError("verify failed") }, launch: { _ in }, writeReport: {},
            move: { source, target in
                if target == f.failed { throw TASError("move denied") }
                try FileManager.default.moveItem(at: source, to: target)
            }))
        XCTAssertEqual(try version(f.backup), "old")
        XCTAssertEqual(try version(f.target), "new")
    }

    func testReportFailureAfterLaunchKeepsRunningNewBundle() throws {
        let f = try fixture()
        var launched = false
        let outcome = try UpdateInstallationTransaction.install(staging: f.staging, target: f.target, backup: f.backup, failed: f.failed,
            verify: { XCTAssertEqual(try self.version($0), "new") },
            launch: { XCTAssertEqual(try self.version($0), "new"); launched = true },
            writeReport: { throw TASError("report disk full") })
        XCTAssertTrue(launched)
        XCTAssertNotNil(outcome.reportWarning)
        XCTAssertEqual(try version(f.target), "new")
        XCTAssertEqual(try version(f.backup), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.failed.path))
    }
}
