import XCTest
@testable import TASCore

final class GenerationKeyTests: XCTestCase {
    func testKeyringRejectsMalformedIdentifiersAndSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tas-keyring-validation-\(UUID().uuidString)")
        try Paths.privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = "Keyring-Password2026!"
        try Configuration.create(directory: directory, password: password, token: "123:fixture", chatID: "-1")
        let config = try Configuration(directory: directory, password: password)
        let original = try Data(contentsOf: config.url)
        let keyID = config.generationID
        for ring: JSON in [
            ["manifestKey": "short", "current": keyID, "keys": config.generations],
            ["manifestKey": config.encryptionPassword, "current": "not-a-uuid", "keys": ["not-a-uuid": config.generations[keyID]!]],
            ["manifestKey": config.encryptionPassword, "current": keyID, "keys": [keyID: "weak"]],
            ["manifestKey": config.encryptionPassword, "current": keyID, "keys": [keyID: config.generations[keyID]!, "unknown": "weak"]]
        ] {
            var tampered = try jsonObject(original)
            tampered["wrappedKeyring"] = try Crypto.encrypt(jsonData(ring), password: password).base64EncodedString()
            try Paths.atomicWrite(jsonData(tampered), to: config.url)
            XCTAssertThrowsError(try Configuration(directory: directory, password: password), "invalid ring: \(ring)")
        }
        try Paths.atomicWrite(original, to: config.url)
        XCTAssertNoThrow(try Configuration(directory: directory, password: password))
    }
    func testJournalRejectsUnknownObjectKeyBeforeCommittingRecoveryPointer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tas-key-journal-\(UUID().uuidString)")
        try Paths.privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = "Journal-Password2026!"
        try Configuration.create(directory: directory, password: password, token: "123:fixture", chatID: "-1")
        let remote = FakeTelegram()
        var vault: Vault? = try Vault(directory: directory, password: password, transport: remote)
        let source = directory.appendingPathComponent("input.txt")
        try Paths.atomicWrite(Data("saved content".utf8), to: source)
        _ = try await vault!.upload(source)
        let db = try Database(directory: directory)
        let baseline = try db.manifest()
        var bad = baseline
        var objects = try XCTUnwrap(bad["files"] as? [JSON])
        objects[0]["key_id"] = UUID().uuidString
        bad["files"] = objects
        let config = try Configuration(directory: directory, password: password)
        let original = try Data(contentsOf: config.url)
        let pointer: JSON = ["fileId": "unreachable", "botId": "primary"]
        let record: JSON = ["phase": "uploaded", "snapshot": bad, "pointer": pointer,
                            "owners": try ManifestJournal.owners(config).base64EncodedString()]
        try ManifestJournal.store(record, db: db, password: config.encryptionPassword)
        vault = nil
        XCTAssertThrowsError(try Vault(directory: directory, password: password, transport: remote))
        XCTAssertEqual(try db.rows("SELECT key_id FROM files").first?["key_id"] as? String,
                       baseline["files"].flatMap { ($0 as? [JSON])?.first?["key_id"] } as? String)
        XCTAssertEqual(try Data(contentsOf: config.url), original)
        XCTAssertEqual(try db.rows("SELECT id FROM manifest_journal").count, 1)
    }
    func testConfigOnlyOnNewDeviceRecoversAllGenerations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tas-device-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let old = "Initial-Password2026!", next = "Replacement-Password2026!"
        try Configuration.create(directory: first, password: old, token: "123:fixture", chatID: "-1")
        let remote = FakeTelegram()
        var vault: Vault? = try Vault(directory: first, password: old, transport: remote)
        let input = root.appendingPathComponent("input")
        try Paths.atomicWrite(Data("first generation".utf8), to: input)
        _ = try await vault!.upload(input, name: "item.txt")
        try await vault!.changePassword(old: old, new: next, confirmation: next)
        let replacement = root.appendingPathComponent("replacement")
        try Paths.atomicWrite(Data("second generation".utf8), to: replacement)
        _ = try await vault!.upload(replacement, name: "item.txt", replace: true)
        vault = nil
        try Paths.privateDirectory(second)
        try Paths.atomicWrite(Data(contentsOf: first.appendingPathComponent("config.json")), to: second.appendingPathComponent("config.json"))
        let recovered = try Vault(directory: second, password: next, transport: remote)
        _ = try await recovered.rebuildIndex()
        let files = try await recovered.files()
        let file = try XCTUnwrap(files.first)
        let destination = root.appendingPathComponent("restored")

        try await recovered.download(file.id, to: destination, version: 1)
        XCTAssertEqual(try Data(contentsOf: destination), Data("first generation".utf8))
        try await recovered.download(file.id, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("second generation".utf8))
    }
    func testRotationKeepsPendingGenerationAndRejectsUnknownManifestKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tas-generation-pending-\(UUID().uuidString)")
        try Paths.privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = "Initial-Password2026!", next = "Replacement-Password2026!"
        try Configuration.create(directory: directory, password: old, token: "123:fixture", chatID: "-1")
        let remote = FakeTelegram()
        let vault = try Vault(directory: directory, password: old, transport: remote)
        let source = directory.appendingPathComponent("pending.txt")
        try Paths.atomicWrite(Data("pending content".utf8), to: source)
        remote.failSend = true
        do { _ = try await vault.upload(source); XCTFail("expected staged upload failure") } catch {}
        remote.failSend = false
        let db = try Database(directory: directory)
        let pendingID = try XCTUnwrap(db.rows("SELECT id FROM pending_uploads").first.map { number($0["id"]) })
        let original = try XCTUnwrap(db.rows("SELECT key_id FROM pending_uploads WHERE id=?", [pendingID]).first?["key_id"] as? String)
        try await vault.changePassword(old: old, new: next, confirmation: next)
        XCTAssertEqual(try db.rows("SELECT key_id FROM pending_uploads WHERE id=?", [pendingID]).first?["key_id"] as? String, original)
        let resumed = try await vault.resume()
        XCTAssertNil(resumed.warning)
        XCTAssertEqual(try db.rows("SELECT key_id FROM files").first?["key_id"] as? String, original)
        let available = try await vault.files()
        let file = try XCTUnwrap(available.first)
        let destination = directory.appendingPathComponent("download.txt")
        try await vault.download(file.id, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("pending content".utf8))
        var corrupt = try db.manifest()
        var files = try XCTUnwrap(corrupt["files"] as? [JSON])
        files[0]["key_id"] = UUID().uuidString
        corrupt["files"] = files
        let other = try Database(directory: directory.appendingPathComponent("other"))
        XCTAssertThrowsError(try other.importManifest(corrupt, keyIDs: Set(Configuration(directory: directory, password: next).generations.keys)))
    }
    func testRotationCreatesFreshGenerationWhileKeepingHistoricalAndRemoteRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tas-generations-\(UUID().uuidString)")
        try Paths.privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = "Initial-Password2026!", next = "Replacement-Password2026!"
        try Configuration.create(directory: directory, password: old, token: "123:fixture", chatID: "-1")
        let remote = FakeTelegram()
        var vault: Vault? = try Vault(directory: directory, password: old, transport: remote)
        let source = directory.appendingPathComponent("item.txt")
        try Paths.atomicWrite(Data("old bytes".utf8), to: source)
        _ = try await vault!.upload(source)
        let db = try Database(directory: directory)
        let firstID = try XCTUnwrap(db.rows("SELECT key_id FROM files").first?["key_id"] as? String)
        try await vault!.changePassword(old: old, new: next, confirmation: next)
        try Paths.atomicWrite(Data("new bytes".utf8), to: source)
        _ = try await vault!.upload(source, replace: true)
        let ids = try db.rows("SELECT key_id FROM files ORDER BY id").compactMap { $0["key_id"] as? String }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(firstID, ids[0])
        vault = nil
        vault = try Vault(directory: directory, password: next, transport: remote)
        let available = try await vault!.files()
        let file = try XCTUnwrap(available.first)
        let output = directory.appendingPathComponent("restored.txt")
        try await vault!.download(file.id, to: output, version: 1)
        XCTAssertEqual(try Data(contentsOf: output), Data("old bytes".utf8))
        _ = try await vault!.rebuildIndex()
        XCTAssertEqual(try db.rows("SELECT key_id FROM files ORDER BY id").compactMap { $0["key_id"] as? String }, ids)
        XCTAssertThrowsError(try Configuration(directory: directory, password: old))
    }
}
