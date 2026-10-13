import XCTest
@testable import TASCore

final class PasswordChangeTests: XCTestCase {
    private let old = "Original-Key2026!"
    private let next = "Replacement-Key2026!"
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tas-password-\(UUID().uuidString)")
        try Paths.privateDirectory(directory)
        try Configuration.create(directory: directory, password: old, token: "123:fixture", chatID: "-1")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testChangedLoginRetainsManifestKeyAndExistingTokens() async throws {
        let original = try Configuration(directory: directory, password: old).encryptionPassword
        var vault: Vault? = try Vault(directory: directory, password: old, transport: FakeTelegram())
        try await vault!.changePassword(old: old, new: next, confirmation: next)
        XCTAssertThrowsError(try Configuration(directory: directory, password: old))
        XCTAssertEqual(try Configuration(directory: directory, password: next).bots.first?.token, "123:fixture")
        XCTAssertEqual(try Configuration(directory: directory, password: next).encryptionPassword, original)
        vault = nil
        let reopened = try Vault(directory: directory, password: next, transport: FakeTelegram())
        let reopenedBots = await reopened.bots()
        XCTAssertEqual(reopenedBots.first?.id, "primary")
    }

    func testInvalidOldMismatchAndWeakNewLeaveConfigUnchanged() async throws {
        let vault = try Vault(directory: directory, password: old, transport: FakeTelegram())
        let before = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        for (previous, proposed, confirmation) in [("wrong", next, next), (old, next, "different"), (old, "weak", "weak")] {
            do { try await vault.changePassword(old: previous, new: proposed, confirmation: confirmation); XCTFail("accepted invalid change") }
            catch { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("config.json")), before) }
        }
        XCTAssertNoThrow(try Configuration(directory: directory, password: old))
        XCTAssertThrowsError(try Configuration(directory: directory, password: next))
    }

    func testFailedConfigWritePreservesSessionAndReopen() async throws {
        let vault = try Vault(directory: directory, password: old, transport: FakeTelegram())
        let configURL = directory.appendingPathComponent("config.json")
        let saved = directory.appendingPathComponent("saved-config.json")
        let before = try Data(contentsOf: configURL)
        try FileManager.default.moveItem(at: configURL, to: saved)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: false)
        do { try await vault.changePassword(old: old, new: next, confirmation: next); XCTFail("write should fail") }
        catch { XCTAssertEqual(try Data(contentsOf: saved), before) }
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.moveItem(at: saved, to: configURL)
        let sessionBots = await vault.bots()
        XCTAssertEqual(sessionBots.first?.id, "primary")
        XCTAssertNoThrow(try Configuration(directory: directory, password: old))
        XCTAssertThrowsError(try Configuration(directory: directory, password: next))
    }

    func testReopenDownloadsExistingCiphertextAndRestoresRemoteIndex() async throws {
        let remote = FakeTelegram()
        var vault: Vault? = try Vault(directory: directory, password: old, transport: remote)
        let source = directory.appendingPathComponent("source.txt")
        let payload = Data("encrypted before login change".utf8)
        try Paths.atomicWrite(payload, to: source)
        _ = try await vault!.upload(source)
        let before = try await vault!.files()
        try await vault!.changePassword(old: old, new: next, confirmation: next)
        vault = nil
        vault = try Vault(directory: directory, password: next, transport: remote)
        let target = directory.appendingPathComponent("download.txt")
        try await vault!.download(try XCTUnwrap(before.first).id, to: target)
        XCTAssertEqual(try Data(contentsOf: target), payload)
        _ = try await vault!.rebuildIndex()
        let recovered = try await vault!.files()
        XCTAssertEqual(recovered.map(\.filename), ["source.txt"])
        try await vault!.updateBot("primary", enabled: true)
        XCTAssertEqual(number(try jsonObject(Data(contentsOf: directory.appendingPathComponent("config.json")))["configVersion"]), 5)
        vault = nil
        XCTAssertThrowsError(try Vault(directory: directory, password: old, transport: remote))
        XCTAssertNoThrow(try Vault(directory: directory, password: next, transport: remote))
    }

    func testExistingJournalDecryptsOnNewLoginAndSessionUsesOriginalSecret() async throws {
        let remote = FakeTelegram()
        var vault: Vault? = try Vault(directory: directory, password: old, transport: remote)
        let source = directory.appendingPathComponent("journal.txt")
        try Paths.atomicWrite(Data("journal content".utf8), to: source)
        _ = try await vault!.upload(source)
        let config = try Configuration(directory: directory, password: old)
        let db = try Database(directory: directory)
        let pointer = try XCTUnwrap(config.raw["remoteManifest"] as? JSON)
        let snapshot = try db.manifest()
        let record: JSON = ["phase": "uploaded", "owners": try ManifestJournal.owners(config).base64EncodedString(), "pointer": pointer, "snapshot": snapshot]
        try ManifestJournal.store(record, db: db, password: config.encryptionPassword)
        try await vault!.changePassword(old: old, new: next, confirmation: next)
        vault = nil
        let reopened = try Vault(directory: directory, password: next, transport: remote)
        let recoveredBefore = try await reopened.files()
        XCTAssertEqual(recoveredBefore.map(\.filename), ["journal.txt"])
        XCTAssertTrue(try db.rows("SELECT * FROM manifest_journal").isEmpty)
        _ = try await reopened.backupIndex()
        _ = try await reopened.rebuildIndex()
        let recoveredAfter = try await reopened.files()
        XCTAssertEqual(recoveredAfter.map(\.filename), ["journal.txt"])
    }

    func testSecondChangeRewrapsManifestKeyAndRejectsPriorLogins() async throws {
        let original = try Configuration(directory: directory, password: old).encryptionPassword
        var vault: Vault? = try Vault(directory: directory, password: old, transport: FakeTelegram())
        try await vault!.changePassword(old: old, new: next, confirmation: next)
        vault = nil
        vault = try Vault(directory: directory, password: next, transport: FakeTelegram())
        let latest = "Third-Login2026!"
        try await vault!.changePassword(old: next, new: latest, confirmation: latest)
        XCTAssertThrowsError(try Configuration(directory: directory, password: old))
        XCTAssertThrowsError(try Configuration(directory: directory, password: next))
        XCTAssertEqual(try Configuration(directory: directory, password: latest).encryptionPassword, original)
    }

    func testMissingOrCorruptSecretEnvelopeFailsClosed() async throws {
        let vault = try Vault(directory: directory, password: old, transport: FakeTelegram())
        try await vault.changePassword(old: old, new: next, confirmation: next)
        let configURL = directory.appendingPathComponent("config.json")
        let original = try Data(contentsOf: configURL)
        var raw = try jsonObject(original)
        raw.removeValue(forKey: "wrappedKeyring")
        try Paths.atomicWrite(jsonData(raw), to: configURL)
        XCTAssertThrowsError(try Configuration(directory: directory, password: next))
        raw["wrappedKeyring"] = "not-an-envelope"
        try Paths.atomicWrite(jsonData(raw), to: configURL)
        XCTAssertThrowsError(try Configuration(directory: directory, password: next))
        try Paths.atomicWrite(original, to: configURL)
    }
}
