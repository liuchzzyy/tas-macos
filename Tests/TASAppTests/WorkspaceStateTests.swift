import XCTest
@testable import TASCore
@testable import TASApp

final class WorkspaceStateTests: XCTestCase {
    #if !TAS_UI_PREVIEW
    @MainActor func testRealModelReservesEditorAndAcceptsExactlyOneOperation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tas-model-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Configuration.create(directory: directory, password: "Fixture-Secret2026!", token: "123:fixture", chatID: "-1")
        let model = AppModel()
        model.directory = directory
        model.vault = try Vault(directory: directory, password: "Fixture-Secret2026!")
        model.autoSync = true
        XCTAssertTrue(model.beginSettingsDialog())
        XCTAssertTrue(model.presentingDialog, "Global modal state must include settings for updater/command guards")
        XCTAssertFalse(model.canOperate)
        XCTAssertFalse(model.run("auto-sync") { _, _ in XCTFail("Editor owns the slot"); return .init("no") })
        model.busy = true
        XCTAssertFalse(model.submitSettingsDialog("rejected") { _, _ in XCTFail("Busy submission"); return .init("no") })
        model.busy = false
        XCTAssertTrue(model.canSubmitSettingsDialog, "Rejected submission keeps editor reservation")
        var executed = 0
        XCTAssertTrue(model.submitSettingsDialog("accepted") { _, _ in executed += 1; return .init("fixture result") })
        XCTAssertTrue(model.busy)
        XCTAssertFalse(model.submitSettingsDialog("duplicate") { _, _ in XCTFail("Duplicate"); return .init("no") })
        model.endSettingsDialog()
        XCTAssertFalse(model.canOperate, "Dismissal must not release a running operation")
        for _ in 0..<1000 where model.busy { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(model.busy)
        XCTAssertEqual(executed, 1)
        XCTAssertEqual(model.logs.entries.first?.message, "fixture result")
        XCTAssertTrue(model.canOperate)
        model.lock()
        XCTAssertTrue(model.logs.entries.isEmpty)
        XCTAssertNil(model.vault)
    }
    #endif

    func testDialogReservationExcludesAutoSyncUntilDismissal() {
        var gate = SettingsDialogCoordinator()
        XCTAssertFalse(gate.reserve(connected: false, busy: false, otherDialog: false))
        XCTAssertFalse(gate.reserve(connected: true, busy: true, otherDialog: false))
        XCTAssertTrue(gate.reserve(connected: true, busy: false, otherDialog: false))
        XCTAssertFalse(gate.allowsBackgroundOperation)
        XCTAssertFalse(gate.reserve(connected: true, busy: false, otherDialog: false))
        XCTAssertTrue(gate.canSubmit(connected: true, busy: false, otherDialog: false))
        XCTAssertFalse(gate.canSubmit(connected: true, busy: true, otherDialog: false))
        XCTAssertFalse(gate.canSubmit(connected: false, busy: false, otherDialog: false))
        XCTAssertTrue(gate.isPresented, "Rejected submission must preserve the editor")
        gate.dismiss()
        XCTAssertTrue(gate.allowsBackgroundOperation)
        XCTAssertFalse(gate.canSubmit(connected: true, busy: false, otherDialog: false))
    }

    @MainActor func testDisconnectedModelNeverAcceptsOrExecutesSubmission() {
        let model = AppModel()
        XCTAssertFalse(model.beginSettingsDialog())
        XCTAssertFalse(model.submitSettingsDialog("test") { _, _ in
            XCTFail("A rejected operation must not execute")
            return .init("unexpected")
        })
        XCTAssertFalse(model.busy)
    }
}
