import XCTest
import TASCore
@testable import TASApp

final class UploadInputTests: XCTestCase {
    func testTypedDropRejectsWholeMixedBatchAndPreservesFolderHierarchy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("报告")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("nested/file.txt")
        try Data("test".utf8).write(to: file)
        XCTAssertNoThrow(try UploadKind.files.validate([file]))
        XCTAssertNoThrow(try UploadKind.folders.validate([folder]))
        XCTAssertThrowsError(try UploadKind.files.validate([file, folder]))
        XCTAssertThrowsError(try UploadKind.folders.validate([folder, file]))
        XCTAssertThrowsError(try UploadKind.files.validate([URL(string: "https://example.com/file")!]))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertThrowsError(try UploadKind.folders.validate([link]))
        XCTAssertEqual(try UploadPlan.collect([folder]).map(\.name), ["报告/nested/file.txt"])
    }
}
