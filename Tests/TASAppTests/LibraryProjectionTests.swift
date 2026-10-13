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
    func testSelectingFolderResolvesAllDescendantFilesIncludingCollapsedRows() {
        let files = [file(1, "a/one.txt"), file(2, "a/nested/two.txt"), file(3, "outside.txt")]
        var cache = LibraryProjection()
        cache.update(files: files, expanded: [], expandAll: false)
        let selection = LibrarySelection.resolve(["folder:a"], rows: cache.rows, allFiles: files)
        XCTAssertEqual(selection.map(\.id), [1, 2])
    }

    func testSelectingFolderAndFileDeduplicatesTargets() {
        let files = [file(1, "a/one.txt"), file(2, "a/two.txt")]
        var cache = LibraryProjection()
        cache.update(files: files, expanded: ["a"], expandAll: false)
        let selection = LibrarySelection.resolve(["folder:a", "file:1"], rows: cache.rows, allFiles: files)
        XCTAssertEqual(selection.map(\.id), [1, 2])
    }

    func testFolderSelectionIncludesFilesHiddenBySearch() {
        let all = [file(1, "a/matched.txt"), file(2, "a/hidden.txt"), file(3, "other.txt")]
        var cache = LibraryProjection()
        cache.update(files: [all[0]], expanded: [], expandAll: true)
        XCTAssertEqual(LibrarySelection.resolve(["folder:a"], rows: cache.rows, allFiles: all).map(\.id), [1, 2])
    }
    func testFolderTargetsDoNotIncludeSiblingWithSamePrefix() {
        let files = [file(1, "a/one.txt"), file(2, "archive/two.txt")]
        let targets = LibrarySelection.targets(["folder:a"], allFiles: files)
        XCTAssertEqual(targets.map(\.id), [1])
    }
    func testFolderDownloadKeepsHierarchy() throws {
        let files = [file(1, "a/one.txt"), file(2, "a/nested/two.txt")]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tas-hierarchy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try LibrarySelection.hierarchicalDestinations(files, in: root).map(\.path),
                       [root.appendingPathComponent("a/one.txt").path, root.appendingPathComponent("a/nested/two.txt").path])
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
