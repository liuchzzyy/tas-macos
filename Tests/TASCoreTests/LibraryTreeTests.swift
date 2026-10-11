import XCTest
@testable import TASCore

final class LibraryTreeTests: XCTestCase {
    private func file(_ id: Int64, _ path: String, deleted: Bool = false) -> StoredFile {
        StoredFile([
            "id": id, "filename": path, "hash": "hash-\(id)",
            "original_size": 123, "stored_size": 97, "chunks": 2, "compressed": 1,
            "created_at": "2026-01-01", "updated_at": "2026-01-02",
            "version_number": 3, "version_count": 4, "object_id": id + 100,
            "deleted": deleted ? 1 : 0, "sync_paused": 1
        ], tags: ["原始标签"])
    }

    func testNestedUnicodeFoldersRetainAllFilesIncludingNameCollisions() throws {
        let originals = [file(1, "相册/旅行/图像.png"), file(2, "工作/图像.png"),
                         file(3, "相册"), file(4, "相册/旧图.png", deleted: true)]
        let roots = LibraryTree.build(originals)
        let album = try XCTUnwrap(roots.first { $0.path == "相册" && $0.isFolder })
        XCTAssertEqual(album.id, "folder:相册")
        XCTAssertEqual(album.name, "相册")
        XCTAssertNil(album.file)
        let trip = try XCTUnwrap(album.children.first { $0.path == "相册/旅行" })
        XCTAssertEqual(trip.id, "folder:相册/旅行")
        XCTAssertEqual(trip.name, "旅行")
        XCTAssertEqual(trip.children.first?.name, "图像.png")
        XCTAssertEqual(trip.children.first?.path, "相册/旅行/图像.png")
        func leaves(_ nodes: [LibraryNode]) -> [StoredFile] {
            nodes.flatMap { node in node.file.map { [$0] } ?? leaves(node.children) }
        }
        XCTAssertEqual(leaves(roots).sorted { $0.id < $1.id }, originals.sorted { $0.id < $1.id })
        XCTAssertEqual(roots.first { $0.id == "file:3" }?.file, originals[2])
    }

    func testFoldersFirstNaturalOrderingIsIndependentOfInputOrder() {
        let originals = [file(10, "z10/b10"), file(2, "z2/b2"), file(3, "z2/b10"),
                         file(4, "a10"), file(5, "a2"), file(6, "A2"), file(7, "a2")]
        let roots = LibraryTree.build(originals)
        XCTAssertEqual(roots.map(\.id), ["folder:z2", "folder:z10", "file:6", "file:5", "file:7", "file:4"])
        XCTAssertEqual(roots.first?.children.map(\.name), ["b2", "b10"])
        XCTAssertEqual(LibraryTree.build(originals.reversed()), roots)
        XCTAssertEqual(LibraryTree.build(Array(originals.dropFirst()) + [originals[0]]), roots)
    }

    func testVisibleRowsUseFolderPathsAndKeepCollapsedDescendantsHidden() {
        let roots = LibraryTree.build([file(1, "a/b/x"), file(2, "a/y"), file(3, "z")])
        let collapsed = LibraryTree.visibleRows(roots, expanded: [])
        XCTAssertEqual(collapsed.map(\.id), ["folder:a", "file:3"])
        XCTAssertEqual(collapsed.map(\.depth), [0, 0])
        XCTAssertEqual(LibraryTree.visibleRows(roots, expanded: ["folder:a", "a/b"]).map(\.id), collapsed.map(\.id))
        let partial = LibraryTree.visibleRows(roots, expanded: ["a"])
        XCTAssertEqual(partial.map(\.id), ["folder:a", "folder:a/b", "file:2", "file:3"])
        XCTAssertEqual(partial.map(\.depth), [0, 1, 1, 0])
        let full = LibraryTree.visibleRows(roots, expanded: ["a", "a/b"])
        XCTAssertEqual(full.map(\.id), ["folder:a", "folder:a/b", "file:1", "file:2", "file:3"])
        XCTAssertEqual(full.map(\.depth), [0, 1, 2, 1, 0])
        XCTAssertEqual(full.map(\.node), LibraryTree.visibleRows(roots, expanded: [], expandAll: true).map(\.node))
        let filtered = LibraryTree.build([file(1, "a/b/x")])
        XCTAssertEqual(LibraryTree.visibleRows(filtered, expanded: [], expandAll: true).map(\.id),
                       ["folder:a", "folder:a/b", "file:1"])
        XCTAssertEqual(filtered[0].id, roots[0].id)
    }

    func testStandaloneFileKeepsCompleteStoredIdentity() throws {
        let original = file(42, "报告.txt", deleted: true)
        let node = try XCTUnwrap(LibraryTree.build([original]).first)
        XCTAssertEqual(node.id, "file:42")
        XCTAssertEqual(node.name, "报告.txt")
        XCTAssertEqual(node.path, original.filename)
        XCTAssertEqual(node.file, original)
        XCTAssertFalse(node.isFolder)
        XCTAssertTrue(node.children.isEmpty)
        XCTAssertTrue(LibraryTree.build([]).isEmpty)
    }
}
