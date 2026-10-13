import XCTest
import AppKit
import TASCore
@testable import TASApp

final class UploadInputTests: XCTestCase {
    func testExplicitFileURLDataIsDecoded() throws {
        let url = URL(fileURLWithPath: "/private/var/tmp/tas-drop-test.txt")
        let data = url.dataRepresentation
        XCTAssertEqual(UploadDropLoader.url(from: data as NSData)?.path, url.path)
    }
    func testFinderFileURLDropDecodesRealProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tas-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: file)
        let folder = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let providers = [NSItemProvider(contentsOf: file)!, NSItemProvider(contentsOf: folder)!]
        let urls = await UploadDropLoader.urls(from: providers)
        XCTAssertEqual(urls.map(\.path), [file.path, folder.path])
        XCTAssertNoThrow(try UploadKind.filesAndFolders.validate(urls))
    }
    func testDropRejectsNonFileURL() async {
        let provider = NSItemProvider(object: URL(string: "https://example.com")! as NSURL)
        let result = await UploadDropLoader.url(from: provider)
        XCTAssertNil(result)
    }
    func testUnifiedDropAcceptsFilesAndFoldersTogetherButRejectsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: file)
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertNoThrow(try UploadKind.filesAndFolders.validate([file, folder]))
        XCTAssertThrowsError(try UploadKind.filesAndFolders.validate([file, link]))
        XCTAssertThrowsError(try UploadKind.filesAndFolders.validate([URL(string: "https://example.com")!]))
    }

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
