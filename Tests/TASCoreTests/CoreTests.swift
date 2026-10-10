import XCTest
@testable import TASCore

final class FakeTelegram: TelegramTransport {
    var documents: [String: Data] = [:]
    var owners: [String: String] = [:]
    var counter = 0
    var failSend = false
    var failManifest = false
    var corruptDownloads = false
    func check(_ bot: Bot) async throws -> String { "fixture_bot" }
    func send(_ file: URL, caption: String, bot: Bot) async throws -> UploadedChunk {
        if failSend || (failManifest && caption == "tas:m1") { throw TASError("模拟网络故障") }
        counter += 1; let id = "file-\(counter)"; documents[id] = try Data(contentsOf: file); owners[id] = bot.id
        return UploadedChunk(messageID: String(counter), fileID: id)
    }
    func download(_ fileID: String, to destination: URL, bot: Bot) async throws {
        guard var bytes = documents[fileID], owners[fileID] == bot.id else { throw TASError("分块不存在或机器人不匹配") }
        if corruptDownloads && bytes.count > 90 { bytes[90] ^= 1 }
        try Paths.atomicWrite(bytes, to: destination)
    }
    func metadata(_ fileID: String, bot: Bot) async throws -> JSON {
        guard documents[fileID] != nil && owners[fileID] == bot.id else { throw TASError("分块不存在") }; return ["file_path": fileID]
    }
    func delete(_ messageID: String, bot: Bot) async throws { documents.removeValue(forKey: "file-\(messageID)") }
}
final class CoreTests: XCTestCase {
    private var directory: URL!
    private var fixture: JSON!
    private var password: String { string(fixture["password"]) }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tas-test-\(UUID().uuidString)")
        try Paths.privateDirectory(directory)
        fixture = try jsonObject(Data(contentsOf: resource("node-compatibility", "json")))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func resource(_ name: String, _ ext: String) -> URL { Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")! }
    private func seedConfig(in target: URL? = nil) throws {
        // Real v1 config is inexpensive to prepare and exercises legacy token loading.
        try Paths.atomicWrite(jsonData(["configVersion": 1, "passwordHash": fixture["hash"]!, "botToken": fixture["token"]!, "chatId": "-123456", "futureField": "preserve-me"]), to: (target ?? directory!).appendingPathComponent("config.json"))
    }
    func testNodePasswordHashesAndEnvelope() throws {
        XCTAssertEqual(try Crypto.passwordHash(password), fixture["hash"] as? String)
        XCTAssertTrue(try Crypto.verifyPassword(password, hash: string(fixture["legacyHash"])))
        let encrypted = try Data(contentsOf: resource("node-token-envelope", "bin"))
        XCTAssertEqual(String(data: try Crypto.decrypt(encrypted, password: password), encoding: .utf8), fixture["token"] as? String)
        XCTAssertEqual(try Crypto.decrypt(Data(contentsOf: resource("node-empty-envelope", "bin")), password: password), Data())
    }
    func testNodeStreamingGzipEnvelopeAndTamperCleanup() throws {
        let output = directory.appendingPathComponent("compressed")
        try Crypto.decryptFile(resource("node-gzip-envelope", "bin"), to: output, password: password)
        let plaintext = directory.appendingPathComponent("plain")
        try Gzip.decompressFile(output, to: plaintext, limit: number(fixture["originalSize"]))
        XCTAssertEqual(try Crypto.hashFile(plaintext), fixture["sha256"] as? String)
        var corrupt = try Data(contentsOf: resource("node-gzip-envelope", "bin")); corrupt[corrupt.count - 1] ^= 1
        let input = directory.appendingPathComponent("corrupt"); try Paths.atomicWrite(corrupt, to: input)
        let failed = directory.appendingPathComponent("failed")
        XCTAssertThrowsError(try Crypto.decryptFile(input, to: failed, password: password))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
    }
    func testStreamingOutputMatchesOneShotDecoder() throws {
        let plain = Data((0..<(9 * 1024 * 1024 + 29)).map { UInt8($0 % 251) })
        let input = directory.appendingPathComponent("input"); try Paths.atomicWrite(plain, to: input)
        let encrypted = directory.appendingPathComponent("encrypted")
        try Crypto.encryptFile(input, to: encrypted, password: password, compressed: false)
        XCTAssertEqual(try Crypto.decrypt(Data(contentsOf: encrypted), password: password), plain)
        let output = directory.appendingPathComponent("output")
        try Crypto.decryptFile(encrypted, to: output, password: password)
        XCTAssertEqual(try Data(contentsOf: output), plain)
    }
    func testGzipLimitsTruncationAndHeaders() throws {
        let data = Data(repeating: 65, count: 250000)
        let compressed = try Gzip.compress(data)
        XCTAssertEqual(try Gzip.decompress(compressed), data)
        XCTAssertThrowsError(try Gzip.decompress(compressed, limit: 1024))
        XCTAssertThrowsError(try Gzip.decompress(compressed.dropLast(3)))
        let header = try Crypto.header(index: 258, total: 500, compressed: true)
        XCTAssertEqual(header.count, 64); XCTAssertEqual(header[16], 2); XCTAssertEqual(header[17], 1)
        let parsed = try Crypto.parseHeader(header); XCTAssertEqual(parsed.index, 258); XCTAssertEqual(parsed.total, 500); XCTAssertTrue(parsed.compressed)
        XCTAssertThrowsError(try Crypto.header(index: 0, total: 65536, compressed: false))
        XCTAssertThrowsError(try Crypto.parseHeader(Data(repeating: 0, count: 64)))
    }
    func testPathContainmentPermissionsAndLock() throws {
        XCTAssertEqual(try Paths.logical("/a\\b//c"), "a/b/c")
        for invalid in ["", ".", "a/../b", "a/./b", "a\0b"] { XCTAssertThrowsError(try Paths.logical(invalid)) }
        let external = directory.appendingPathComponent("external"); try Paths.privateDirectory(external)
        let root = directory.appendingPathComponent("root"); try Paths.privateDirectory(root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: external)
        XCTAssertThrowsError(try Paths.contained("link/secret", in: root))
        let file = root.appendingPathComponent("file"); try Paths.atomicWrite(Data("private".utf8), to: file)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var lock: VaultLock? = try VaultLock(directory: root)
        XCTAssertThrowsError(try VaultLock(directory: root)); withExtendedLifetime(lock) {}; lock = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sync.lock").path))
        let fresh = try VaultLock(directory: root); withExtendedLifetime(fresh) {}
    }
    func testSchemaMigrationAndTransactionalImport() throws {
        var db: Database? = try Database(directory: directory)
        try db!.script("PRAGMA foreign_keys=OFF; DROP TABLE chunks; DROP TABLE files; CREATE TABLE files(id INTEGER PRIMARY KEY AUTOINCREMENT,filename TEXT NOT NULL,hash TEXT NOT NULL UNIQUE,original_size INTEGER NOT NULL,stored_size INTEGER NOT NULL,chunks INTEGER NOT NULL DEFAULT 1,compressed INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL DEFAULT (datetime('now')),updated_at TEXT NOT NULL DEFAULT (datetime('now'))); CREATE TABLE chunks(id INTEGER PRIMARY KEY AUTOINCREMENT,file_id INTEGER NOT NULL,chunk_index INTEGER NOT NULL,message_id TEXT NOT NULL,file_telegram_id TEXT,size INTEGER NOT NULL,created_at TEXT NOT NULL DEFAULT (datetime('now')),FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE,UNIQUE(file_id,chunk_index));")
        let hash = String(repeating: "a", count: 64)
        let id = try db!.run("INSERT INTO files(filename,hash,original_size,stored_size) VALUES(?,?,?,?)", ["a.txt", hash, 1, 61])
        try db!.run("INSERT INTO chunks(file_id,chunk_index,message_id,file_telegram_id,size) VALUES(?,?,?,?,?)", [id, 0, "1", "legacy-file", 125]); db = nil
        db = try Database(directory: directory)
        try db!.run("INSERT INTO files(filename,hash,original_size,stored_size) VALUES(?,?,?,?)", ["same-bytes.txt", hash, 1, 61])
        XCTAssertEqual(try db!.files().count, 2)
        XCTAssertTrue(try db!.rows("PRAGMA table_info(chunks)").contains { string($0["name"]) == "bot_id" })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("index-before-swift-") })
        var bad = try db!.manifest(); bad["chunks"] = []
        XCTAssertThrowsError(try db!.importManifest(bad)); XCTAssertEqual(try db!.files().count, 2)
        XCTAssertEqual(try db!.files(search: "%").count, 0)
    }
    func testUploadResumeAtomicDownloadManifestRollbackAndRecovery() async throws {
        try seedConfig(); let fake = FakeTelegram(); let vault = try Vault(directory: directory, password: password, transport: fake)
        let source = directory.appendingPathComponent("input.txt"); let bytes = Data("你好，原生 TAS\n".utf8)
        try Paths.atomicWrite(bytes, to: source)
        fake.failSend = true
        do { _ = try await vault.upload(source, name: "nested/a.txt"); XCTFail("should fail") } catch {}
        let pending = try await vault.pending(); XCTAssertEqual(pending.count, 1)
        try FileManager.default.removeItem(at: source); fake.failSend = false
        let resumed = try await vault.resume(); XCTAssertNil(resumed.warning)
        let files = try await vault.files(); XCTAssertEqual(files.count, 1)
        let target = directory.appendingPathComponent("download.txt")
        try Paths.atomicWrite(Data("keep this".utf8), to: target)
        fake.corruptDownloads = true
        do { try await vault.download(files[0].id, to: target); XCTFail("should reject corrupt ciphertext") } catch {}
        XCTAssertEqual(try Data(contentsOf: target), Data("keep this".utf8))
        fake.corruptDownloads = false; try await vault.download(files[0].id, to: target)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        _ = try await vault.tag(files[0].id, value: "Test")
        fake.failManifest = true
        do { _ = try await vault.delete(files[0].id); XCTFail("should rollback deletion") } catch {}
        let after = try await vault.files(); XCTAssertEqual(after.count, 1); XCTAssertEqual(after[0].tags, ["test"])
        fake.failManifest = false
        _ = try await vault.rebuildIndex()
        let rebuilt = try await vault.files(); XCTAssertEqual(rebuilt.map(\.filename), ["nested/a.txt"])
        XCTAssertEqual(rebuilt[0].tags, ["test"])
        let config = try jsonObject(Data(contentsOf: directory.appendingPathComponent("config.json")))
        XCTAssertEqual(config["futureField"] as? String, "preserve-me")
        let verified = try await vault.verify(deep: true); XCTAssertNil(verified.warning)
    }
    func testBotOwnershipAndLastEnabledProtection() async throws {
        try seedConfig(); let fake = FakeTelegram(); let vault = try Vault(directory: directory, password: password, transport: fake)
        try await vault.addBot(id: "second", token: "987:fixture", chatID: "-2")
        try await vault.updateBot("primary", enabled: false)
        do { try await vault.updateBot("second", enabled: false); XCTFail("must keep one enabled") } catch {}
        let source = directory.appendingPathComponent("a.txt"); try Paths.atomicWrite(Data("bot-owned".utf8), to: source)
        _ = try await vault.upload(source)
        do { try await vault.updateBot("second", remove: true); XCTFail("must keep chunk owner") } catch {}
        let files = try await vault.files()
        try await vault.download(files[0].id, to: directory.appendingPathComponent("restored"))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("restored"), encoding: .utf8), "bot-owned")
        let config = try jsonObject(Data(contentsOf: directory.appendingPathComponent("config.json")))
        XCTAssertNil(config["botToken"]); XCTAssertEqual(number(config["configVersion"]), 3)
        XCTAssertEqual(config["futureField"] as? String, "preserve-me")
    }
    func testSyncUsesLegacyRelativePathsAndSourceModificationTimes() async throws {
        let library = directory.appendingPathComponent("library")
        try seedConfig(in: library); let fake = FakeTelegram()
        let vault = try Vault(directory: library, password: password, transport: fake)
        let folder = directory! // This parent contains the vault; its internal files must be excluded.
        do { try await vault.addFolder(library); XCTFail("must exclude vault roots") } catch {}
        let source = folder.appendingPathComponent("note.txt")
        try Paths.atomicWrite(Data("first version".utf8), to: source)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
        try await vault.addFolder(folder)
        let first = try await vault.sync(); XCTAssertNil(first.warning)
        let files = try await vault.files(); XCTAssertEqual(files.map(\.filename), ["note.txt"])
        let sent = fake.counter
        _ = try await vault.sync(); XCTAssertEqual(fake.counter, sent)
        let database = try Database(directory: library)
        let state = try database.rows("SELECT * FROM sync_state").first!
        XCTAssertEqual(number(state["mtime"]), 1_700_000_000_000)
        try Paths.atomicWrite(Data("second version".utf8), to: source)
        _ = try await vault.sync()
        let updated = try await vault.files(); XCTAssertEqual(updated.count, 1)
        XCTAssertNotEqual(updated[0].hash, files[0].hash)
    }

}
