import XCTest
import Security
@testable import TASApp

final class KeychainStoreTests: XCTestCase {
    func testSaveReadUpdateDeleteIsDirectoryScoped() {
        let one = FileManager.default.temporaryDirectory.appendingPathComponent("tas-kc-one-\(UUID().uuidString)")
        let two = FileManager.default.temporaryDirectory.appendingPathComponent("tas-kc-two-\(UUID().uuidString)")
        defer { KeychainStore.delete(for: one); KeychainStore.delete(for: two) }
        XCTAssertNil(KeychainStore.read(for: one))
        XCTAssertTrue(KeychainStore.save("First-Password123!", for: one))
        XCTAssertEqual(KeychainStore.read(for: one), "First-Password123!")
        XCTAssertNil(KeychainStore.read(for: two))
        XCTAssertTrue(KeychainStore.save("Second-Password123!", for: one))
        XCTAssertEqual(KeychainStore.read(for: one), "Second-Password123!")
        KeychainStore.delete(for: one)
        XCTAssertNil(KeychainStore.read(for: one))
    }
    func testAccountNormalisesSystemPathAliases() {
        let first = URL(fileURLWithPath: "/var/tmp/tas-kc-alias")
        let second = URL(fileURLWithPath: "/private/var/tmp/tas-kc-alias")
        XCTAssertEqual(KeychainStore.account(for: first), KeychainStore.account(for: second))
    }
}
