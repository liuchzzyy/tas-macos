import XCTest
@testable import TASCore
@testable import TASApp

final class LibraryProjectionTests: XCTestCase {
    private func file(_ id: Int64, _ name: String, tags: [String] = []) -> StoredFile {
        StoredFile(["id": id, "filename": name, "original_size": 12, "version_number": 1], tags: tags)
    }
    func testExpansionAndSearchDoNotRebuildUnchangedStructure() {
        var cache = LibraryProjection()
        let files = [file(1, "a/b/c.txt"), file(2, "top.txt")]
        cache.update(files: files, expanded: [], expandAll: false)
        XCTAssertEqual(cache.structureBuildCount, 1)
        XCTAssertEqual(cache.rows.map(\.id), ["folder:a", "file:2"])
        cache.update(files: files, expanded: ["a", "a/b"], expandAll: false)
        XCTAssertEqual(cache.rows.map(\.id), ["folder:a", "folder:a/b", "file:1", "file:2"])
        XCTAssertEqual(cache.structureBuildCount, 1)
        cache.update(files: files, expanded: [], expandAll: true)
        XCTAssertEqual(cache.structureBuildCount, 1)
        XCTAssertEqual(cache.folderPaths, ["a", "a/b"])
        cache.update(files: files, expanded: [], expandAll: false)
        XCTAssertFalse(cache.rows.contains { $0.node.file?.id == 1 })
        XCTAssertEqual(cache.structureBuildCount, 1)
    }
    func testMetadataAndSearchResultsInvalidateWithoutLosingStoredIdentity() {
        var cache = LibraryProjection()
        cache.update(files: [file(7, "a/b.txt")], expanded: [], expandAll: true)
        cache.update(files: [file(7, "a/b.txt", tags: ["new"])], expanded: [], expandAll: true)
        XCTAssertEqual(cache.structureBuildCount, 2)
        XCTAssertEqual(cache.rows.last?.node.file?.tags, ["new"])
        XCTAssertEqual(cache.rows.last?.id, "file:7")
        cache.update(files: [], expanded: [], expandAll: true)
        XCTAssertTrue(cache.rows.isEmpty)
        XCTAssertTrue(cache.folderPaths.isEmpty)
    }
    func testMultiSelectionKeepsOnlyVisibleFileIDsAndNeverFolders() {
        let files = [file(1, "a/one.txt"), file(2, "a/two.txt"), file(3, "top.txt")]
        var cache = LibraryProjection()
        cache.update(files: files, expanded: ["a"], expandAll: false)
        let selection = LibrarySelection.resolve(["folder:a", "file:1", "file:2", "file:999"], rows: cache.rows)
        XCTAssertEqual(selection.map(\.id), [1, 2])
        cache.update(files: files, expanded: [], expandAll: false)
        XCTAssertTrue(LibrarySelection.resolve(["file:1", "file:2"], rows: cache.rows).isEmpty)
        cache.update(files: [file(2, "a/two.txt")], expanded: [], expandAll: true)
        XCTAssertEqual(LibrarySelection.resolve(["file:1", "file:2"], rows: cache.rows).map(\.id), [2])
    }
    func testBatchDownloadNamesDisambiguateSameLeafAndPreserveIDs() {
        let files = [file(1, "a/report.txt"), file(2, "b/report.txt")]
        XCTAssertEqual(LibrarySelection.downloadNames(files), ["report-1.txt", "report-2.txt"])
    }
    func testBatchDownloadNamesAvoidCollisionWithAlreadyNamedFile() {
        let files = [file(1, "a/report.txt"), file(2, "b/report.txt"), file(3, "report-1.txt")]
        let names = LibrarySelection.downloadNames(files)
        XCTAssertEqual(Set(names).count, files.count)
        XCTAssertTrue(names.contains("report-1.txt"))
    }
}
