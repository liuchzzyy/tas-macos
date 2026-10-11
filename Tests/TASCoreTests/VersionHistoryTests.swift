import XCTest
import CSQLite
@testable import TASCore

private final class DiskTelegram: TelegramTransport {
    let root: URL
    var crashOnDelete = false
    init(root: URL) { self.root = root }
    func check(_ bot: Bot) async throws -> String { "fixture" }
    func send(_ file: URL, caption: String, bot: Bot) async throws -> UploadedChunk {
        let id = UUID().uuidString
        try Paths.atomicWrite(Data(contentsOf: file), to: root.appendingPathComponent(id))
        return UploadedChunk(messageID: id, fileID: id)
    }
    func download(_ fileID: String, to destination: URL, bot: Bot) async throws {
        try Paths.atomicWrite(Data(contentsOf: root.appendingPathComponent(fileID)), to: destination)
    }
    func metadata(_ fileID: String, bot: Bot) async throws -> JSON {
        ["file_size": try Data(contentsOf: root.appendingPathComponent(fileID)).count]
    }
    func delete(_ messageID: String, bot: Bot) async throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(messageID))
        if crashOnDelete { _exit(77) }
    }
}

final class VersionHistoryTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("vault") }
    private let password = "Version-Test2026!"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tas-versions-\(UUID().uuidString)")
        try Paths.privateDirectory(root)
        try Configuration.create(directory: directory, password: password, token: "123:fixture", chatID: "-1")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func source(_ text: String) throws -> URL {
        let url = root.appendingPathComponent("source.txt")
        try Paths.atomicWrite(Data(text.utf8), to: url); return url
    }
    func testFolderUploadRoundTripRetainsHierarchyAndHistory() async throws {
        let fake = FakeTelegram()
        let vault = try Vault(directory: directory, password: password, transport: fake)
        let rootFolder = root.appendingPathComponent("实验记录")
        try Paths.privateDirectory(rootFolder.appendingPathComponent("第一天"))
        let input = rootFolder.appendingPathComponent("第一天/结果.txt")
        try Paths.atomicWrite(Data("first".utf8), to: input)
        try Paths.atomicWrite(Data("overview".utf8), to: rootFolder.appendingPathComponent("说明.txt"))
        let plan = try UploadPlan.collect([rootFolder])
        XCTAssertEqual(plan.count, 2)
        for item in plan { _ = try await vault.upload(item.url, name: item.name) }
        let files = try await vault.files()
        let rows = LibraryTree.visibleRows(LibraryTree.build(files), expanded: [], expandAll: true)
        XCTAssertEqual(Set(rows.compactMap { $0.node.file?.filename }), ["实验记录/第一天/结果.txt", "实验记录/说明.txt"])
        XCTAssertEqual(rows.filter { $0.node.isFolder }.map { $0.node.path }, ["实验记录", "实验记录/第一天"])
        let selected = try XCTUnwrap(files.first { $0.filename.hasSuffix("结果.txt") })
        try Paths.atomicWrite(Data("second".utf8), to: input)
        _ = try await vault.upload(input, name: selected.filename, replace: true)
        let history = try await vault.history(selected.id)
        XCTAssertEqual(history.map(\.number), [2, 1])
        let output = root.appendingPathComponent("download.txt")
        try await vault.download(selected.id, to: output, version: 1)
        XCTAssertEqual(try Data(contentsOf: output), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: input), Data("second".utf8))
        let folders = try await vault.folders()
        XCTAssertTrue(folders.isEmpty, "One-time folder upload must not register continuous sync")
    }

    func testHistoryDownloadRestoreAndCurrentHashSkip() async throws {
        let fake = FakeTelegram()
        let vault = try Vault(directory: directory, password: password, transport: fake)
        _ = try await vault.upload(source("A"), name: "note.txt", message: "first")
        let initial = try await vault.files()[0]
        _ = try await vault.upload(source("B"), name: "note.txt", replace: true)
        var history = try await vault.history(initial.id)
        XCTAssertEqual(history.map(\.number), [2, 1])
        XCTAssertEqual(history.last?.message, "first")
        let out = root.appendingPathComponent("old.txt")
        try await vault.download(initial.id, to: out, version: 1)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "A")
        let sent = fake.counter
        _ = try await vault.upload(source("B"), name: "note.txt", replace: true)
        XCTAssertEqual(fake.counter, sent)
        _ = try await vault.restoreVersion(initial.id, version: 1, message: "rollback")
        XCTAssertEqual(fake.counter, sent + 1, "restore sends only manifest, not content")
        history = try await vault.history(initial.id)
        XCTAssertEqual(history.map(\.number), [3, 2, 1])
        XCTAssertEqual(history.first?.restoredFromVersionID, history.last?.id)
        let current = try await vault.files()[0]
        XCTAssertTrue(current.syncPaused)
        XCTAssertEqual(current.id, initial.id)
        XCTAssertEqual(current.hash, initial.hash)
        let stats = try await vault.statistics()
        XCTAssertEqual(stats.files, 1); XCTAssertEqual(stats.versions, 3)
        let check = try await vault.verify(deep: true, allVersions: true)
        XCTAssertNil(check.warning)
        _ = try await vault.resumeSync(initial.id)
        let resumed = try await vault.files(includeDeleted: true)[0]
        XCTAssertFalse(resumed.syncPaused)
    }
    func testManifestRoundTripAndMalformedImportAreAtomic() async throws {
        let fake = FakeTelegram()
        let vault = try Vault(directory: directory, password: password, transport: fake)
        _ = try await vault.upload(source("A"), name: "note.txt")
        let id = try await vault.files()[0].id
        _ = try await vault.upload(source("B"), name: "note.txt", replace: true)
        _ = try await vault.restoreVersion(id, version: 1)
        let db = try Database(directory: directory)
        let manifest = try db.manifest()
        XCTAssertEqual(number(manifest["schemaVersion"]), 2)
        let other = try Database(directory: root.appendingPathComponent("copy"))
        try other.importManifest(manifest)
        XCTAssertEqual(try other.history(id).count, 3)
        XCTAssertTrue(try other.files()[0].syncPaused)
        var bad = manifest
        var versions = try XCTUnwrap(manifest["versions"] as? [JSON])
        versions[0]["number"] = 99; bad["versions"] = versions
        XCTAssertThrowsError(try other.importManifest(bad))
        XCTAssertEqual(try other.history(id).map(\.number), [3,2,1])
        _ = try await vault.rebuildIndex()
        let recovered = try await vault.history(id)
        XCTAssertEqual(recovered.count, 3)
    }
    func testSoftDeletePurgeAndFailedPublishRollback() async throws {
        let fake = FakeTelegram()
        let vault = try Vault(directory: directory, password: password, transport: fake)
        _ = try await vault.upload(source("A"), name: "note.txt")
        let id = try await vault.files()[0].id
        _ = try await vault.upload(source("B"), name: "note.txt", replace: true)
        do { _ = try await vault.delete(id, hard: true); XCTFail("active purge must fail") } catch {}
        fake.failManifest = true
        do { _ = try await vault.restoreVersion(id, version: 1); XCTFail("restore publish should fail") } catch {}
        let retained = try await vault.history(id)
        XCTAssertEqual(retained.count, 2)
        do { _ = try await vault.delete(id); XCTFail("delete publish should fail") } catch {}
        let active = try await vault.files(); XCTAssertEqual(active.count, 1)
        fake.failManifest = false
        _ = try await vault.delete(id)
        let visible = try await vault.files(); XCTAssertTrue(visible.isEmpty)
        let deleted = try await vault.files(includeDeleted: true); XCTAssertTrue(deleted[0].deleted)
        XCTAssertEqual(deleted[0].versionCount, 2)
        do { _ = try await vault.upload(source("C"), name: "note.txt", replace: true); XCTFail("must not resurrect deleted") } catch {}
        do { _ = try await vault.resumeSync(id); XCTFail("deleted resume must fail") } catch {}
        _ = try await vault.restoreVersion(id, version: 1)
        let restored = try await vault.files()[0]; XCTAssertTrue(restored.syncPaused)
        _ = try await vault.delete(id)
        fake.failManifest = true
        do { _ = try await vault.delete(id, hard: true); XCTFail("purge publish should fail") } catch {}
        let preserved = try await vault.history(id); XCTAssertEqual(preserved.count, 3)
        fake.failManifest = false
        _ = try await vault.delete(id, hard: true)
        let remaining = try await vault.files(includeDeleted: true); XCTAssertTrue(remaining.isEmpty)
        let stats = try await vault.statistics(); XCTAssertEqual(stats.storedBytes, 0)
        XCTAssertEqual(fake.documents.count, 1, "only current manifest remains")
    }
    func testOldClientWritesFailClosedAndTagsUseLogicalIDs() async throws {
        let vault = try Vault(directory: directory, password: password, transport: FakeTelegram())
        _ = try await vault.upload(source("A"), name: "a.txt")
        _ = try await vault.upload(source("B"), name: "a.txt", replace: true)
        _ = try await vault.upload(source("C"), name: "b.txt")
        let b = try await vault.files().first { $0.filename == "b.txt" }!
        _ = try await vault.tag(b.id, value: "keep")
        let db = try Database(directory: directory)
        XCTAssertEqual(string(try db.rows("PRAGMA foreign_key_list(tags)").first?["table"]), "logical_files")
        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.url.path, &legacy), SQLITE_OK)
        defer { sqlite3_close(legacy) }
        for sql in ["DELETE FROM files", "UPDATE files SET filename='broken'", "DELETE FROM tags", "INSERT INTO files(filename,hash,original_size,stored_size) VALUES('x','x',1,1)", "DELETE FROM pending_uploads"] {
            XCTAssertNotEqual(sqlite3_exec(legacy, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        XCTAssertEqual(try db.files().count, 2)
    }
    func testLegacyMigrationBacksUpAndPreservesDuplicateNames() throws {
        let old = root.appendingPathComponent("legacy"); try Paths.privateDirectory(old)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(old.appendingPathComponent("index.db").path, &connection), SQLITE_OK)
        let sql = "CREATE TABLE files(id INTEGER PRIMARY KEY AUTOINCREMENT,filename TEXT NOT NULL,hash TEXT NOT NULL,original_size INTEGER NOT NULL,stored_size INTEGER NOT NULL,chunks INTEGER NOT NULL DEFAULT 1,compressed INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL DEFAULT 'old',updated_at TEXT NOT NULL DEFAULT 'old'); INSERT INTO files(filename,hash,original_size,stored_size) VALUES('a','a',1,1),('a','b',1,1),('a (imported-2)','c',1,1);"
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(connection)
        let db = try Database(directory: old)
        let files = try db.files()
        XCTAssertEqual(files.count, 3); XCTAssertEqual(Set(files.map(\.filename)).count, 3)
        XCTAssertEqual(Set(files.map(\.id)), Set([1,2,3]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: old.path).contains { $0.hasPrefix("index-before-versions-") })
        XCTAssertEqual(try db.history(1).first?.createdAt, "old")
    }
    func testSyncPauseResumeABAAndDeletedTombstone() async throws {
        let fake = FakeTelegram()
        let vault = try Vault(directory: directory, password: password, transport: fake)
        let folder = root.appendingPathComponent("sync"); try Paths.privateDirectory(folder)
        let source = folder.appendingPathComponent("a.txt")
        try Paths.atomicWrite(Data("A".utf8), to: source); try await vault.addFolder(folder)
        _ = try await vault.sync(); let id = try await vault.files()[0].id
        try Paths.atomicWrite(Data("B".utf8), to: source); _ = try await vault.sync()
        try Paths.atomicWrite(Data("A".utf8), to: source); _ = try await vault.sync()
        var history = try await vault.history(id); XCTAssertEqual(history.count, 3)
        _ = try await vault.restoreVersion(id, version: 2)
        let sent = fake.counter; _ = try await vault.sync(); XCTAssertEqual(fake.counter, sent)
        let db = try Database(directory: directory); XCTAssertTrue(try db.files()[0].syncPaused)
        _ = try await vault.rebuildIndex()
        _ = try await vault.sync(); history = try await vault.history(id); XCTAssertEqual(history.count, 4)
        _ = try await vault.resumeSync(id); _ = try await vault.sync()
        history = try await vault.history(id); XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history.first?.source, "sync")
        _ = try await vault.delete(id); let afterDelete = fake.counter
        try Paths.atomicWrite(Data("C".utf8), to: source); _ = try await vault.sync()
        XCTAssertEqual(fake.counter, afterDelete)
        let tombstone = try await vault.files(includeDeleted: true)[0]; XCTAssertTrue(tombstone.deleted)
    }
    func testSyncConflictsDetectedBeforeAnyUploads() async throws {
        let fake = FakeTelegram()
        let vault = try Vault(directory: directory, password: password, transport: fake)
        for name in ["one", "two"] {
            let folder = root.appendingPathComponent(name); try Paths.privateDirectory(folder)
            try Paths.atomicWrite(Data(name.utf8), to: folder.appendingPathComponent("same.txt"))
            try Paths.atomicWrite(Data(name.utf8), to: folder.appendingPathComponent("unique-\(name).txt"))
            try await vault.addFolder(folder)
        }
        do { let result = try await vault.sync(); XCTAssertNotNil(result.warning) } catch {}
        XCTAssertEqual(fake.counter, 0)
        let files = try await vault.files(); XCTAssertTrue(files.isEmpty)
    }
    func testPendingBlocksMutationsAndRecoveryThenResumesOnce() async throws {
        let fake = FakeTelegram()
        let vault = try Vault(directory: directory, password: password, transport: fake)
        _ = try await vault.upload(source("A"), name: "a.txt")
        let id = try await vault.files()[0].id
        fake.failSend = true
        do { _ = try await vault.upload(source("B"), name: "a.txt", replace: true, message: "resumed"); XCTFail() } catch {}
        fake.failSend = false
        do { _ = try await vault.restoreVersion(id, version: 1); XCTFail("pending restore") } catch {}
        do { _ = try await vault.delete(id); XCTFail("pending delete") } catch {}
        do { _ = try await vault.rebuildIndex(); XCTFail("pending rebuild") } catch {}
        _ = try await vault.resume(); _ = try await vault.resume()
        let history = try await vault.history(id); XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.message, "resumed")
        let pending = try await vault.pending(); XCTAssertTrue(pending.isEmpty)
    }
    func testMalformedManifestValidationRejectsEveryBrokenGraphAtomically() async throws {
        let vault = try Vault(directory: directory, password: password, transport: FakeTelegram())
        _ = try await vault.upload(source("A"), name: "a.txt")
        _ = try await vault.upload(source("B"), name: "a.txt", replace: true)
        _ = try await vault.upload(source("C"), name: "b.txt")
        let db = try Database(directory: directory), good = try Database(directory: directory).manifest()
        let baseline = try jsonData(good.filter { $0.key != "createdAt" })
        let mutations: [(String, Int, String, Any)] = [
            ("versions", 0, "number", 2), ("versions", 0, "object_id", 999),
            ("versions", 1, "restored_from_version_id", 3), ("logicalFiles", 0, "current_version_id", 3),
            ("logicalFiles", 1, "filename", "a.txt"), ("files", 0, "hash", String(repeating: "z", count: 64)),
            ("files", 0, "stored_size", -1), ("chunks", 0, "size", 1),
            ("files", 0, "original_size", "not-a-number"), ("versions", 0, "number", 1.5),
            ("logicalFiles", 0, "deleted", "invalid"), ("versions", 1, "id", 1)
        ]
        for (table, index, field, value) in mutations {
            var bad = good; var records = try XCTUnwrap(bad[table] as? [JSON]); records[index][field] = value; bad[table] = records
            XCTAssertThrowsError(try db.importManifest(bad), "\(table).\(field)=\(value)")
            XCTAssertEqual(try jsonData(db.manifest().filter { $0.key != "createdAt" }), baseline)
        }
    }
    func testV1ImportPreservesDuplicateNamesTagsAndContent() async throws {
        let fake = FakeTelegram(), vault = try Vault(directory: directory, password: password, transport: FakeTelegram())
        _ = fake // Content bytes are validated through the transport in other tests.
        _ = try await vault.upload(source("A"), name: "a.txt")
        _ = try await vault.upload(source("B"), name: "a.txt", replace: true)
        let db = try Database(directory: directory)
        var legacy = try db.manifest(); legacy["schemaVersion"] = 1; legacy.removeValue(forKey: "logicalFiles"); legacy.removeValue(forKey: "versions")
        legacy["tags"] = [["id": 1, "file_id": 2, "tag": "old", "created_at": "old"]]
        let copy = try Database(directory: root.appendingPathComponent("v1-copy")); try copy.importManifest(legacy)
        let files = try copy.files(); XCTAssertEqual(files.count, 2)
        XCTAssertEqual(Set(files.map(\.filename)).count, 2)
        XCTAssertEqual(files.first { $0.id == 2 }?.tags, ["old"])
        XCTAssertEqual(try copy.history(2).first?.source, "migration")
    }
    func testPurgePreservesSharedContentAndUniqueStorageAccounting() async throws {
        let fake = FakeTelegram(), vault = try Vault(directory: directory, password: password, transport: FakeTelegram())
        _ = fake
        _ = try await vault.upload(source("A"), name: "a.txt")
        let db = try Database(directory: directory), a = try db.files()[0]
        let b = try db.run("INSERT INTO logical_files(filename) VALUES('b.txt')")
        try db.appendVersion(b, objectID: a.objectID, source: "upload")
        _ = try await vault.tag(b, value: "shared")
        let stats = try await vault.statistics(); XCTAssertEqual(stats.files, 2); XCTAssertEqual(stats.versions, 2)
        XCTAssertEqual(stats.storedBytes, a.storedSize); XCTAssertEqual(stats.originalBytes, a.originalSize * 2)
        _ = try await vault.delete(a.id); _ = try await vault.delete(a.id, hard: true)
        let out = root.appendingPathComponent("shared.txt"); try await vault.download(b, to: out)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "A")
        XCTAssertEqual(try db.files()[0].tags, ["shared"])
        XCTAssertEqual(try db.rows("PRAGMA foreign_key_check").count, 0)
    }
    func testPurgePreservesMessagesAcrossLegacyAndBotAliases() async throws {
        for alias: String? in [nil, "alias"] {
            let location = root.appendingPathComponent(UUID().uuidString)
            try Configuration.create(directory: location, password: password, token: "123:fixture", chatID: "-1")
            let fake = FakeTelegram(), vault = try Vault(directory: location, password: password, transport: FakeTelegram())
            // Keep a single transport for the entire graph and verify the retained bytes.
            _ = fake
            _ = try await vault.upload(source("A"), name: "a.txt")
            try await vault.addBot(id: "alias", token: "456:fixture", chatID: "-1", endpoint: "https://api.telegram.org/")
            try await vault.updateBot("alias", enabled: false)
            let db = try Database(directory: location), a = try db.files()[0]
            let object = try db.run("INSERT INTO files(filename,hash,original_size,stored_size,chunks,compressed) SELECT 'b.txt',hash,original_size,stored_size,chunks,compressed FROM files WHERE id=?", [a.objectID])
            try db.run("INSERT INTO chunks(file_id,chunk_index,message_id,file_telegram_id,bot_id,size) SELECT ?,chunk_index,message_id,file_telegram_id,'primary',size FROM chunks WHERE file_id=?", [object, a.objectID])
            try db.run("UPDATE chunks SET bot_id=? WHERE file_id=?", [alias, a.objectID])
            let b = try db.run("INSERT INTO logical_files(filename) VALUES('b.txt')")
            try db.appendVersion(b, objectID: object, source: "upload")
            _ = try await vault.delete(a.id); _ = try await vault.delete(a.id, hard: true)
            let output = location.appendingPathComponent("retained.txt")
            try await vault.download(b, to: output)
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "A")
        }
    }
    func testManifestRejectsAggregateSizeOverflowBeforeReplacingDatabase() async throws {
        let vault = try Vault(directory: directory, password: password, transport: FakeTelegram())
        _ = try await vault.upload(source("A"), name: "a.txt")
        _ = try await vault.upload(source("B"), name: "b.txt")
        let db = try Database(directory: directory)
        var manifest = try db.manifest()
        var objects = try XCTUnwrap(manifest["files"] as? [JSON])
        for i in objects.indices { objects[i]["original_size"] = Int64.max }
        manifest["files"] = objects
        XCTAssertThrowsError(try db.importManifest(manifest))
        XCTAssertEqual(try db.files().map(\.originalSize), [1, 1])
    }
    func testExistingLocalOverflowThrowsInsteadOfCrashingStatistics() throws {
        let db = try Database(directory: directory)
        for name in ["a", "b"] {
            try db.run("INSERT INTO files(filename,hash,original_size,stored_size) VALUES(?,?,?,?)", [name, String(repeating: "a", count: 64), Int64.max, 1])
        }
        XCTAssertThrowsError(try db.statistics())
    }
    func testLegacyPendingWithoutSizeColumnsResumesAndRebuilds() async throws {
        for (uploaded, compressed) in [(false, false), (true, false), (false, true), (true, true)] {
            let location = root.appendingPathComponent(UUID().uuidString)
            try Configuration.create(directory: location, password: password, token: "123:fixture", chatID: "-1")
            let plain = try source("legacy bytes"), encrypted = location.appendingPathComponent("encrypted")
            try Crypto.encryptFile(plain, to: encrypted, password: password, compressed: compressed)
            let payload = try Data(contentsOf: encrypted)
            let chunk = location.appendingPathComponent("chunk")
            try Paths.atomicWrite(try Crypto.header(index: 0, total: 1, compressed: compressed) + payload, to: chunk)
            let fake = FakeTelegram()
            if uploaded {
                let config = try Configuration(directory: location, password: password)
                _ = try await fake.send(chunk, caption: "legacy", bot: config.owner(nil))
                try FileManager.default.removeItem(at: chunk)
            }
            // A genuinely old schema, not a modern pending row with a hand-set zero.
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(location.appendingPathComponent("index.db").path, &connection), SQLITE_OK)
            let sql = """
            CREATE TABLE pending_uploads(id INTEGER PRIMARY KEY AUTOINCREMENT,filename TEXT NOT NULL,file_path TEXT NOT NULL,hash TEXT NOT NULL,original_size INTEGER NOT NULL,total_chunks INTEGER NOT NULL,uploaded_chunks INTEGER NOT NULL DEFAULT 0,temp_dir TEXT,created_at TEXT NOT NULL DEFAULT 'old');
            CREATE TABLE pending_chunks(id INTEGER PRIMARY KEY AUTOINCREMENT,pending_id INTEGER NOT NULL,chunk_index INTEGER NOT NULL,chunk_path TEXT NOT NULL,uploaded INTEGER NOT NULL DEFAULT 0,message_id TEXT,file_telegram_id TEXT,FOREIGN KEY(pending_id) REFERENCES pending_uploads(id) ON DELETE CASCADE,UNIQUE(pending_id,chunk_index));
            INSERT INTO pending_uploads(filename,file_path,hash,original_size,total_chunks,uploaded_chunks) VALUES('legacy.bin','unused','\(try Crypto.hashFile(plain))',12,1,\(uploaded ? 1 : 0));
            INSERT INTO pending_chunks(pending_id,chunk_index,chunk_path,uploaded,message_id,file_telegram_id) VALUES(1,0,'\(chunk.path)',\(uploaded ? 1 : 0),'1','file-1');
            """
            XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(connection)
            let vault = try Vault(directory: location, password: password, transport: fake)
            let result = try await vault.resume(); XCTAssertNil(result.warning)
            let files = try await vault.files(); XCTAssertEqual(files.first?.storedSize, Int64(payload.count))
            let db = try Database(directory: location)
            XCTAssertEqual(number(try db.rows("SELECT size FROM chunks").first?["size"]), Int64(payload.count + Crypto.headerSize))
            _ = try await vault.rebuildIndex()
            let output = location.appendingPathComponent("output")
            try await vault.download(try XCTUnwrap(files.first).id, to: output)
            XCTAssertEqual(try Data(contentsOf: output), Data("legacy bytes".utf8))
            let count = fake.counter; _ = try await vault.resume(); XCTAssertEqual(fake.counter, count)
        }
    }
    func testBackupRejectsMalformedLocalSnapshotWithoutMovingPointer() async throws {
        let fake = FakeTelegram(), vault = try Vault(directory: directory, password: password, transport: FakeTelegram())
        _ = fake
        _ = try await vault.upload(source("A"), name: "a.txt")
        let original = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let db = try Database(directory: directory)
        try db.run("UPDATE chunks SET size=0")
        do { _ = try await vault.backupIndex(); XCTFail("invalid snapshot must never be published") } catch {}
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("config.json")), original)
    }
    func testCrashWorker() async throws {
        guard let path = ProcessInfo.processInfo.environment["TAS_TEST_CRASH_ROOT"] else { return }
        let location = URL(fileURLWithPath: path)
        let transport = DiskTelegram(root: location.appendingPathComponent("remote"))
        let vault = try Vault(directory: location.appendingPathComponent("vault"), password: password, transport: transport, publicationBoundary: { boundary in
            if ProcessInfo.processInfo.environment["TAS_TEST_POINT"] == boundary { _exit(77) }
        })
        let action = ProcessInfo.processInfo.environment["TAS_TEST_ACTION"] ?? "restore"
        if action == "seed" {
            let input = location.appendingPathComponent("input")
            try Paths.atomicWrite(Data("A".utf8), to: input); _ = try await vault.upload(input, name: "a.txt")
            try Paths.atomicWrite(Data("B".utf8), to: input); _ = try await vault.upload(input, name: "a.txt", replace: true)
        } else if action == "check" {
            let local = try await vault.files(includeDeleted: true)
            let config = try Configuration(directory: location.appendingPathComponent("vault"), password: password)
            let pointer = try XCTUnwrap(config.raw["remoteManifest"] as? JSON)
            let bytes = try Data(contentsOf: transport.root.appendingPathComponent(string(pointer["fileId"])))
            let snapshot = try jsonObject(Gzip.decompress(Crypto.decrypt(bytes, password: password)))
            let logical = try XCTUnwrap((snapshot["logicalFiles"] as? [JSON])?.first)
            let versions = try XCTUnwrap(snapshot["versions"] as? [JSON])
            XCTAssertEqual(local.first?.versionCount, versions.count)
            XCTAssertEqual(local.first?.syncPaused, number(logical["sync_paused"]) != 0)
            _ = try await vault.backupIndex()
            let history = try await vault.history(try XCTUnwrap(local.first).id)
            XCTAssertEqual(history.count, versions.count, "backup after restart must not erase restored event")
        } else {
            transport.crashOnDelete = true
            _ = try await vault.restoreVersion(1, version: 1)
        }
    }
    private func crashWorker(_ location: URL, action: String, point: String = "") throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
        process.arguments = ["-XCTest", "TASCoreTests.VersionHistoryTests/testCrashWorker", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["TAS_TEST_CRASH_ROOT"] = location.path; environment["TAS_TEST_ACTION"] = action
        environment["TAS_TEST_POINT"] = point
        process.environment = environment
        let log = location.appendingPathComponent("\(action)-\(point).log")
        let output = try Paths.privateFile(log); defer { try? output.close() }
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 && process.terminationStatus != 77 {
            XCTFail(try String(contentsOf: log, encoding: .utf8))
        }
        return process.terminationStatus
    }
    func testCrashAtOldManifestDeletionReconcilesBeforeNextBackup() throws {
        let location = root.appendingPathComponent("crash"); try Paths.privateDirectory(location)
        try Configuration.create(directory: location.appendingPathComponent("vault"), password: password, token: "123:fixture", chatID: "-1")
        XCTAssertEqual(try crashWorker(location, action: "seed"), 0)
        XCTAssertEqual(try crashWorker(location, action: "restore"), 77)
        XCTAssertEqual(try crashWorker(location, action: "check"), 0)
    }
    func testConfigWriteFailureKeepsJournalUntilRecovery() async throws {
        let fake = FakeTelegram()
        let configURL = directory.appendingPathComponent("config.json")
        let savedURL = directory.appendingPathComponent("config.saved")
        let vault = try Vault(directory: directory, password: password, transport: fake, publicationBoundary: { point in
            if point == "databaseCommitted" {
                try FileManager.default.moveItem(at: configURL, to: savedURL)
                try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: false)
            }
        })
        _ = try await vault.upload(source("A"), name: "a.txt")
        _ = try await vault.upload(source("B"), name: "a.txt", replace: true)
        do { _ = try await vault.restoreVersion(1, version: 1); XCTFail("config write must fail") } catch {}
        let db = try Database(directory: directory)
        XCTAssertFalse(try db.rows("SELECT * FROM manifest_journal").isEmpty)
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.moveItem(at: savedURL, to: configURL)
        _ = try await vault.backupIndex()
        let files = try await vault.files()
        XCTAssertEqual(files.first?.versionCount, 3)
        XCTAssertEqual(files.first?.syncPaused, true)
        XCTAssertTrue(try db.rows("SELECT * FROM manifest_journal").isEmpty)
        _ = try await vault.rebuildIndex()
        let recovered = try await vault.history(1)
        XCTAssertEqual(recovered.count, 3)
    }
    func testCrashAtEveryPublicationBoundaryRecoversConsistently() throws {
        for point in ["prepared", "uploaded", "receiptStored", "databaseCommitted", "pointerFinalized", "journalCleared"] {
            let location = root.appendingPathComponent(point); try Paths.privateDirectory(location)
            try Configuration.create(directory: location.appendingPathComponent("vault"), password: password, token: "123:fixture", chatID: "-1")
            XCTAssertEqual(try crashWorker(location, action: "seed"), 0)
            XCTAssertEqual(try crashWorker(location, action: "restore", point: point), 77, point)
            XCTAssertEqual(try crashWorker(location, action: "check"), 0, point)
            let database = try Database(directory: location.appendingPathComponent("vault"))
            XCTAssertEqual(try database.history(1).count, ["prepared", "uploaded"].contains(point) ? 2 : 3, point)
            XCTAssertTrue(try database.rows("SELECT * FROM manifest_journal").isEmpty)
        }
    }
    func testReplacementKeepsStableLogicalIdentity() async throws {
        let vault = try Vault(directory: directory, password: password, transport: FakeTelegram())
        _ = try await vault.upload(source("A"), name: "note.txt")
        let before = try await vault.files()
        _ = try await vault.upload(source("B"), name: "note.txt", replace: true)
        let after = try await vault.files()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.id, before.first?.id)
        XCTAssertNotEqual(after.first?.hash, before.first?.hash)
    }
}
