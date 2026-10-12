import XCTest
import Darwin
@testable import TASCore

final class CryptoSourceSafetyTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("tas-source-\(UUID().uuidString)")
        try Paths.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testOpenedSourceSurvivesAncestorReplacement() throws {
        let root = try fixture()
        let original = root.appendingPathComponent("directory")
        let moved = root.appendingPathComponent("moved")
        let outside = root.appendingPathComponent("outside")
        try Paths.privateDirectory(original)
        try Paths.privateDirectory(outside)
        try Data("original".utf8).write(to: original.appendingPathComponent("input"))
        try Data("replacement".utf8).write(to: outside.appendingPathComponent("input"))
        let handle = try Crypto.openSource(original.appendingPathComponent("input"))
        defer { try? handle.close() }
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        XCTAssertEqual(try handle.readToEnd(), Data("original".utf8))
        XCTAssertThrowsError(try Crypto.openSource(original.appendingPathComponent("input")))
    }

    func testFIFOAndDirectoryAreRejectedWithoutBlocking() throws {
        let root = try fixture()
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try Crypto.hashFile(fifo))
        XCTAssertThrowsError(try Crypto.hashFile(root))
    }

    func testHashAndEncryptionRejectLeafAndAncestorSymlinks() throws {
        let root = try fixture()
        let real = root.appendingPathComponent("real")
        try Paths.privateDirectory(real)
        let source = real.appendingPathComponent("input")
        try Data("secret".utf8).write(to: source)
        let leaf = root.appendingPathComponent("leaf")
        let ancestor = root.appendingPathComponent("ancestor")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: source)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: real)
        for link in [leaf, ancestor.appendingPathComponent("input")] {
            XCTAssertThrowsError(try Crypto.hashFile(link))
            XCTAssertThrowsError(try Crypto.encryptFile(link, to: root.appendingPathComponent(UUID().uuidString), password: "fixture", compressed: false))
        }
    }
}
