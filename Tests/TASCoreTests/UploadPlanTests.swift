import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import TASCore

final class UploadPlanTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tas-upload-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult private func fixture(_ path: String) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    func testDirectoryIncludesTopLevelFolderAndSkipsHiddenDescendants() throws {
        let first = try fixture("相册/旅行/图2.txt")
        let second = try fixture("相册/图10.txt")
        try fixture("相册/.secret")
        try fixture("相册/.private/nested.txt")
        let root = directory.appendingPathComponent("相册")
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let candidates = try UploadPlan.collect([root])
        XCTAssertEqual(Set(candidates.map(\.name)), ["相册/旅行/图2.txt", "相册/图10.txt"])
        XCTAssertEqual(Set(candidates.map(\.url)), [first, second])
        XCTAssertTrue(try UploadPlan.collect([empty]).isEmpty)
    }

    func testRejectsRemoteURLsSymlinksAndSpecialFilesWithoutFollowingThem() throws {
        let regular = try fixture("outside/file.txt")
        let folder = directory.appendingPathComponent("outside")
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let directoryLink = directory.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: folder)
        let dangling = directory.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing")
        let fifo = directory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for source in [URL(string: "https://example.com/file.txt")!,
                       URL(string: "file://remote.example/tmp/file.txt")!, link, directoryLink, dangling, fifo] {
            XCTAssertThrowsError(try UploadPlan.collect([regular, source]), source.absoluteString) { error in
                XCTAssertTrue(error is TASError, "\(error)")
            }
        }
        let root = directory.appendingPathComponent("selected")
        try fixture("selected/good.txt")
        let escape = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: folder)
        XCTAssertThrowsError(try UploadPlan.collect([root]))
        try FileManager.default.removeItem(at: escape)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: regular)
        XCTAssertThrowsError(try UploadPlan.collect([root]))
        try FileManager.default.removeItem(at: escape)
        XCTAssertEqual(mkfifo(escape.path, 0o600), 0)
        XCTAssertThrowsError(try UploadPlan.collect([root]))
    }

    func testRepeatedAndOverlappingSelectionDeduplicatesOnlyIdenticalMappings() throws {
        let source = try fixture("root/nested/file2.txt")
        try fixture("root/file10.txt")
        try fixture("root/file2.txt")
        let root = directory.appendingPathComponent("root")
        let nested = root.appendingPathComponent("nested")
        let selection = [root, source, nested, root, source]
        let candidates = try UploadPlan.collect(selection)
        XCTAssertEqual(candidates.map(\.name), ["file2.txt", "nested/file2.txt", "root/file2.txt", "root/file10.txt", "root/nested/file2.txt"])
        XCTAssertEqual(candidates.filter { $0.url == source }.count, 3)
        XCTAssertEqual(try UploadPlan.collect(selection.reversed()), candidates)
        XCTAssertEqual(try UploadPlan.collect([source, source.resolvingSymlinksInPath()]).count, 1)
    }

    func testDuplicateTargetsFromDifferentSourcesAbortTheWholePlan() throws {
        let first = try fixture("one/same.txt")
        let second = try fixture("two/same.txt")
        XCTAssertThrowsError(try UploadPlan.collect([first, second])) { error in
            guard let error = error as? TASError else { return XCTFail("Expected TASError, got \(error)") }
            XCTAssertTrue(error.message.contains("same.txt"))
            XCTAssertTrue(error.message.contains("one"))
            XCTAssertTrue(error.message.contains("two"))
        }
        try fixture("one/shared/x.txt")
        try fixture("two/shared/x.txt")
        XCTAssertThrowsError(try UploadPlan.collect([directory.appendingPathComponent("one/shared"),
                                                   directory.appendingPathComponent("two/shared")]))
        let sameContent = try Data(contentsOf: first)
        XCTAssertEqual(try Data(contentsOf: second), sameContent)
    }

    func testLogicalPathsAreValidatedWithoutSilentlyRewritingSourceNames() throws {
        for path in ["bad\\..\\escape", "back\\slash.txt", "folder/back\\slash.txt"] {
            let source = try fixture(path)
            XCTAssertThrowsError(try UploadPlan.collect([source])) { error in
                XCTAssertTrue(error is TASError)
            }
        }
        XCTAssertThrowsError(try UploadPlan.collect([directory.appendingPathComponent("folder")]))
        let safe = try fixture("safe/100% #? 中文.txt")
        let candidate = try XCTUnwrap(UploadPlan.collect([safe]).first)
        XCTAssertEqual(candidate.name, "100% #? 中文.txt")
        XCTAssertEqual(try Paths.logical(candidate.name), candidate.name)
    }

    func testUnreadableOrMissingEntriesAbortInsteadOfReturningPartialResults() throws {
        try XCTSkipIf(geteuid() == 0, "Root bypasses POSIX read permissions")
        let good = try fixture("selected/good.txt")
        XCTAssertThrowsError(try UploadPlan.collect([good, directory.appendingPathComponent("missing")]))
        let blocked = try fixture("selected/blocked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path) }
        XCTAssertThrowsError(try UploadPlan.collect([good, blocked]))
        XCTAssertThrowsError(try UploadPlan.collect([directory.appendingPathComponent("selected")]))
        try fixture("other/inaccessible/child.txt")
        let inaccessible = directory.appendingPathComponent("other/inaccessible")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: inaccessible.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inaccessible.path) }
        XCTAssertThrowsError(try UploadPlan.collect([directory.appendingPathComponent("other")]))
    }

    func testCancelledTaskReturnsNoPlanEvenForEmptySelection() async throws {
        let source = try fixture("folder/file.txt")
        let selections = [[], [source], [source.deletingLastPathComponent()]]
        for selection in selections {
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try UploadPlan.collect(selection)
            }
            do {
                _ = try await task.value
                XCTFail("Cancelled traversal must not return candidates")
            } catch is CancellationError {
                // Cancellation remains distinguishable from filesystem failure.
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
        }
    }

    func testExplicitSelectionThroughSymlinkedFolderIsRejected() throws {
        let source = try fixture("outside/secret.txt")
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.deletingLastPathComponent())
        XCTAssertThrowsError(try UploadPlan.collect([link.appendingPathComponent("secret.txt")]))
    }

    func testStandaloneFileUsesBasenameAndPreservesSelectedHiddenFile() throws {
        let source = try fixture("父目录/.私有.txt")
        let candidates = try UploadPlan.collect([source])
        XCTAssertEqual(candidates, [UploadCandidate(url: source, name: ".私有.txt")])
        XCTAssertTrue(try UploadPlan.collect([]).isEmpty)
    }
}
