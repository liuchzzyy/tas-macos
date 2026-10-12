#if TAS_UI_PREVIEW
import XCTest
@testable import TASApp

final class UIPreviewOptionsTests: XCTestCase {
    func testDefaultsAndCompactSectionParsing() throws {
        let defaults = try UIPreviewOptions(arguments: [])
        XCTAssertEqual(defaults.width, 1120)
        XCTAssertEqual(defaults.height, 760)
        XCTAssertEqual(defaults.section, "overview")
        let compact = try UIPreviewOptions(arguments: ["--ui-width", "960", "--ui-height", "650", "--ui-section", "sync"])
        XCTAssertEqual(compact.width, 960)
        XCTAssertEqual(compact.height, 650)
        XCTAssertEqual(compact.section, "sync")
        for bad in [["--ui-width", "nan"], ["--ui-height", "0"], ["--ui-width"], ["--ui-section", "unknown"]] {
            XCTAssertThrowsError(try UIPreviewOptions(arguments: bad))
        }
    }
    @MainActor func testPreviewCannotOpenOrSubmitEvenWithoutPreviewArguments() {
        let model = AppModel()
        model.open(password: "not-a-real-secret", token: nil, chat: nil, endpoint: nil)
        XCTAssertNil(model.vault)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.configured)
        XCTAssertFalse(model.canOperate)
        XCTAssertFalse(model.beginSettingsDialog())
        XCTAssertFalse(model.run("test") { _, _ in XCTFail("must not run"); return .init("no") })
        XCTAssertNotEqual(model.directory, AppModel().directory)
    }
}
#endif
