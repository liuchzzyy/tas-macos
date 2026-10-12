import XCTest

@testable import TASCore

private final class SQLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func append(_ sql: String) { lock.lock(); defer { lock.unlock() }; recorded.append(sql) }
    func reset() { lock.lock(); defer { lock.unlock() }; recorded.removeAll() }
    var statements: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
}


/// Network seam only: configuration, SQLite, crypto and recovery remain real.
private final class InterruptedTelegram: TelegramTransport {
    let storage = FakeTelegram()
    var chunkAttempts = 0
    var cancelChunk: Int?
    var manifestAttempts = 0
    func check(_ bot: Bot) async throws -> String { try await storage.check(bot) }
    func send(_ file: URL, caption: String, bot: Bot) async throws -> UploadedChunk {
        if caption == "tas:m1" { manifestAttempts += 1 }
        else {
            chunkAttempts += 1
            if chunkAttempts == cancelChunk { throw CancellationError() }
        }
        return try await storage.send(file, caption: caption, bot: bot)
    }
    func download(_ fileID: String, to destination: URL, bot: Bot) async throws {
        try await storage.download(fileID, to: destination, bot: bot)
    }
    func metadata(_ fileID: String, bot: Bot) async throws -> JSON { try await storage.metadata(fileID, bot: bot) }
    func delete(_ messageID: String, bot: Bot) async throws { try await storage.delete(messageID, bot: bot) }
}

final class CoreReliabilityTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("vault") }
    private let password = "Reliable-Test2026!"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tas-reliability-\(UUID().uuidString)")
        try Configuration.create(directory: directory, password: password, token: "123:fixture", chatID: "-1")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func source(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try Paths.atomicWrite(Data(name.utf8), to: url)
        return url
    }
    private func remoteNames(_ transport: InterruptedTelegram) throws -> [String] {
        let config = try Configuration(directory: directory, password: password)
        guard let pointer = config.raw["remoteManifest"] as? JSON else { return [] }
        let bytes = try XCTUnwrap(transport.storage.documents[string(pointer["fileId"])])
        let snapshot = try jsonObject(Gzip.decompress(Crypto.decrypt(bytes, password: password)))
        _ = try Database.validatedManifest(snapshot)
        return (snapshot["logicalFiles"] as? [JSON] ?? []).map { string($0["filename"]) }.sorted()
    }
    func testSyncReadsNoLibraryTagsPerCandidateAndKeepsVersionChecks() async throws {
        let sqlRecorder = SQLRecorder()
        let transport = InterruptedTelegram()
        let vault = try Vault(directory: directory, password: password, transport: transport, queryObserver: sqlRecorder.append)
        let folder = root.appendingPathComponent("sync")
        for name in ["a.txt", "b.txt", "c.txt"] { _ = try source(name, in: folder) }
        try await vault.addFolder(folder)
        _ = try await vault.sync()
        let db = try Database(directory: directory)
        let original = try XCTUnwrap(db.files().first)
        for index in 0..<30 {
            let id = try db.run("INSERT INTO logical_files(filename) VALUES(?)", ["unrelated-\(index)"])
            try db.appendVersion(id, objectID: original.objectID, source: "upload")
            try db.run("INSERT INTO tags(file_id,tag) VALUES(?,?)", [id, "tag-\(index)"])
        }
        sqlRecorder.reset()
        let sends = transport.chunkAttempts
        let result = try await vault.sync()
        XCTAssertNil(result.warning)
        XCTAssertEqual(transport.chunkAttempts, sends)
        let tagReads = sqlRecorder.statements.filter { $0.contains("SELECT tag FROM tags") }.count
        print("SYNC_METRIC candidates=3 library=33 per-file-tag-reads=\(tagReads) statements=\(sqlRecorder.statements.count)")
        XCTAssertEqual(tagReads, 0, "sync needs current content state, not every library file's tags")
        XCTAssertLessThanOrEqual(sqlRecorder.statements.count, 20, "query count must not multiply by library size")
        // A changed candidate must also avoid the full-library lookup in stage().
        try Paths.atomicWrite(Data("new content".utf8), to: folder.appendingPathComponent(original.filename))
        sqlRecorder.reset()
        let changed = try await vault.sync()
        XCTAssertNil(changed.warning)
        XCTAssertEqual(sqlRecorder.statements.filter { $0.contains("SELECT tag FROM tags") }.count, 0)
        XCTAssertEqual(try db.history(original.id).count, 2)
        let after = transport.chunkAttempts
        _ = try await vault.sync()
        XCTAssertEqual(transport.chunkAttempts, after, "successful upload must be visible to the next lookup")
    }
    func testStatisticsUsesNoTagsAndPreservesSharedDeletedHistoryAccounting() throws {
        let recorder = SQLRecorder()
        let db = try Database(directory: directory, queryObserver: recorder.append)
        let old = try db.run("INSERT INTO files(filename,hash,original_size,stored_size) VALUES('a','old',5,10)")
        let latest = try db.run("INSERT INTO files(filename,hash,original_size,stored_size) VALUES('a','new',7,20)")
        let a = try db.run("INSERT INTO logical_files(filename) VALUES('a')")
        try db.appendVersion(a, objectID: old, source: "upload")
        try db.appendVersion(a, objectID: latest, source: "upload")
        let b = try db.run("INSERT INTO logical_files(filename) VALUES('b')")
        try db.appendVersion(b, objectID: latest, source: "restore")
        let deleted = try db.run("INSERT INTO logical_files(filename,deleted) VALUES('deleted',1)")
        try db.appendVersion(deleted, objectID: old, source: "upload")
        for id in [a, b, deleted] { try db.run("INSERT INTO tags(file_id,tag) VALUES(?,'irrelevant')", [id]) }
        recorder.reset()
        let stats = try db.statistics()
        XCTAssertEqual(stats.files, 2); XCTAssertEqual(stats.deletedFiles, 1); XCTAssertEqual(stats.versions, 4)
        XCTAssertEqual(stats.originalBytes, 14); XCTAssertEqual(stats.storedBytes, 30); XCTAssertEqual(stats.historyBytes, 10)
        let tagReads = recorder.statements.filter { $0.contains("FROM tags") }.count
        print("STATISTICS_METRIC per-file-tag-reads=\(tagReads) statements=\(recorder.statements.count)")
        XCTAssertEqual(tagReads, 0)
        XCTAssertLessThanOrEqual(recorder.statements.count, 4)
        try db.run("UPDATE files SET original_size=? WHERE id=?", [Int64.max, latest])
        XCTAssertThrowsError(try db.statistics(), "aggregate overflow remains checked")
    }
    func testBotChangesCommitTogetherOnlyAfterSuccessfulDiskWrite() async throws {
        let transport = InterruptedTelegram()
        let vault = try Vault(directory: directory, password: password, transport: transport)
        try await vault.addBot(id: "secondary", token: "456:fixture", chatID: "-2")
        let configURL = directory.appendingPathComponent("config.json")
        let saved = directory.appendingPathComponent("config.saved")
        try FileManager.default.moveItem(at: configURL, to: saved)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: false)
        do { try await vault.addBot(id: "rejected", token: "789:fixture", chatID: "-3"); XCTFail("disk failure") } catch {}
        do { try await vault.updateBot("secondary", enabled: false); XCTFail("disk failure") } catch {}
        do { try await vault.updateBot("secondary", remove: true); XCTFail("disk failure") } catch {}
        let bots = await vault.bots()
        XCTAssertEqual(bots.map(\.id), ["primary", "secondary"])
        XCTAssertTrue(bots.allSatisfy(\.enabled))
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.moveItem(at: saved, to: configURL)
        // Validation failures must not leak a preceding enabled-state edit either.
        do { try await vault.updateBot("secondary", enabled: false, endpoint: "invalid"); XCTFail("invalid endpoint") } catch {}
        let afterValidation = await vault.bots()
        XCTAssertTrue(afterValidation.allSatisfy(\.enabled))
        _ = try await vault.backupIndex()
        let persisted = try Configuration(directory: directory, password: password)
        XCTAssertEqual(persisted.bots.map(\.id), ["primary", "secondary"])
        XCTAssertTrue(persisted.bots.allSatisfy(\.enabled))
        try await vault.updateBot("secondary", enabled: false)
        XCTAssertFalse(try Configuration(directory: directory, password: password).bots[1].enabled)
    }
    func testDirtyMarkerSurvivesPointerWriteFailureAndMutationJournalRecovery() async throws {
        let transport = InterruptedTelegram()
        let vault = try Vault(directory: directory, password: password, transport: transport)
        let configURL = directory.appendingPathComponent("config.json")
        let saved = directory.appendingPathComponent("config.saved")
        try FileManager.default.moveItem(at: configURL, to: saved)
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: false)
        let result = try await vault.upload(source("a.txt"))
        XCTAssertNotNil(result.warning)
        let db = try Database(directory: directory)
        XCTAssertEqual(try db.rows("SELECT id FROM manifest_dirty").count, 1)
        XCTAssertTrue(try db.rows("SELECT * FROM manifest_journal").isEmpty)
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.moveItem(at: saved, to: configURL)
        let file = try XCTUnwrap(db.files().first)
        transport.storage.failManifest = true
        do { _ = try await vault.delete(file.id); XCTFail("mutation must fail") } catch {}
        XCTAssertFalse(try db.rows("SELECT * FROM manifest_journal").isEmpty)
        transport.storage.failManifest = false
        // begin() discards only the prepared mutation; the independent dirty
        // marker still publishes the committed upload from the earlier operation.
        let resumed = try await vault.resume()
        XCTAssertNil(resumed.warning)
        XCTAssertEqual(try remoteNames(transport), ["a.txt"])
        XCTAssertFalse(try XCTUnwrap(db.files().first).deleted)
        XCTAssertTrue(try db.rows("SELECT * FROM manifest_journal").isEmpty)
        XCTAssertTrue(try db.rows("SELECT id FROM manifest_dirty").isEmpty)
    }
    func testTaskCancellationAfterCommitKeepsPublicationForEmptyResume() async throws {
        let transport = InterruptedTelegram()
        let vault = try Vault(directory: directory, password: password, transport: transport)
        let folder = root.appendingPathComponent("cancel-source")
        _ = try source("a.txt", in: folder); _ = try source("b.txt", in: folder)
        try await vault.addFolder(folder)
        let task = Task {
            try await vault.sync { progress in
                if progress.message.hasPrefix("上传完成 ·") {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await task.value; XCTFail("actual task cancellation must propagate") }
        catch is CancellationError {}
        let files = try await vault.files()
        let pending = try await vault.pending()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(pending.isEmpty, "cancelled before staging the next candidate")
        XCTAssertEqual(transport.manifestAttempts, 0)
        _ = try await vault.resume()
        XCTAssertEqual(try remoteNames(transport), files.map(\.filename))
    }
    func testSyncPendingGuardPrecedesUnchangedFastPath() async throws {
        let transport = InterruptedTelegram()
        let vault = try Vault(directory: directory, password: password, transport: transport)
        let folder = root.appendingPathComponent("pending-source")
        _ = try source("a.txt", in: folder)
        try await vault.addFolder(folder)
        _ = try await vault.sync()
        transport.storage.failSend = true
        do { _ = try await vault.upload(source("replacement.txt"), name: "a.txt", replace: true); XCTFail("staged upload") } catch {}
        transport.storage.failSend = false
        let attempts = transport.chunkAttempts
        let result = try await vault.sync()
        XCTAssertTrue(result.warning?.contains("未完成上传") == true)
        XCTAssertEqual(transport.chunkAttempts, attempts)
        let pending = try await vault.pending()
        let files = try await vault.files()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(files.first?.versionCount, 1)
    }
    func testSaveBotsFailureDoesNotLeakRawIntoLaterSave() throws {
        let config = try Configuration(directory: directory, password: password)
        config.raw["futureField"] = ["keep": "unknown"]
        try config.save()
        let baseline = try jsonData(config.raw)
        let saved = directory.appendingPathComponent("config.saved")
        try FileManager.default.moveItem(at: config.url, to: saved)
        try FileManager.default.createDirectory(at: config.url, withIntermediateDirectories: false)
        let originalBots = config.bots
        config.bots.append(Bot(raw: ["id": "rejected", "chatId": "-2", "botToken": "456:fixture"], token: "456:fixture"))
        XCTAssertThrowsError(try config.saveBots(password: password))
        config.bots = originalBots // Existing Vault caller's rollback cannot repair raw.
        XCTAssertEqual(try jsonData(config.raw), baseline)
        try FileManager.default.removeItem(at: config.url)
        try FileManager.default.moveItem(at: saved, to: config.url)
        config.raw["remoteManifest"] = ["fileId": "later-backup"]
        try config.save()
        let reloaded = try Configuration(directory: directory, password: password)
        XCTAssertEqual(reloaded.bots.map(\.id), ["primary"])
        XCTAssertEqual((reloaded.raw["futureField"] as? JSON)?["keep"] as? String, "unknown")
    }
    func testCancelledResumeRetriesEmptyQueueAndRetainsDirtyAfterPublishFailure() async throws {
        let transport = InterruptedTelegram()
        var vault: Vault? = try Vault(directory: directory, password: password, transport: transport)
        transport.storage.failSend = true
        for name in ["a.txt", "b.txt"] {
            do { _ = try await vault!.upload(source(name)); XCTFail("stage only") }
            catch is TASError {}
        }
        transport.storage.failSend = false
        transport.cancelChunk = transport.chunkAttempts + 2
        do { _ = try await vault!.resume(); XCTFail("second pending upload must cancel") }
        catch is CancellationError {}
        let completed = try await vault!.files()
        XCTAssertEqual(completed.count, 1)
        for item in try await vault!.pending() { _ = try await vault!.clearPending(item.id) }
        vault = nil
        vault = try Vault(directory: directory, password: password, transport: transport)
        transport.storage.failManifest = true
        let failed = try await vault!.resume()
        XCTAssertNotNil(failed.warning, "empty queue must attempt unpublished index")
        XCTAssertEqual(transport.manifestAttempts, 1)
        transport.storage.failManifest = false
        let retried = try await vault!.resume()
        XCTAssertNil(retried.warning)
        XCTAssertEqual(transport.manifestAttempts, 2)
        XCTAssertEqual(try remoteNames(transport), completed.map(\.filename))
        _ = try await vault!.resume()
        XCTAssertEqual(transport.manifestAttempts, 2)
    }
    func testCancelledSyncRetriesCompletedIndexAfterRestartWithoutNewUploads() async throws {
        let transport = InterruptedTelegram()
        let folder = root.appendingPathComponent("source")
        _ = try source("a.txt", in: folder); _ = try source("b.txt", in: folder)
        var vault: Vault? = try Vault(directory: directory, password: password, transport: transport)
        try await vault!.addFolder(folder)
        transport.cancelChunk = 2
        do { _ = try await vault!.sync(); XCTFail("second upload must cancel") }
        catch is CancellationError {} // Completed first upload must remain durable.
        let completed = try await vault!.files()
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(transport.manifestAttempts, 0)
        let pending = try await vault!.pending()
        XCTAssertEqual(pending.count, 1)
        // Remove only the unfinished fixture task/source, making the next sync unchanged.
        for item in pending {
            _ = try await vault!.clearPending(item.id)
            try FileManager.default.removeItem(at: folder.appendingPathComponent(item.filename))
        }
        vault = nil
        vault = try Vault(directory: directory, password: password, transport: transport)
        let attempts = transport.chunkAttempts
        let result = try await vault!.sync()
        XCTAssertNil(result.warning)
        XCTAssertEqual(transport.chunkAttempts, attempts)
        XCTAssertEqual(transport.manifestAttempts, 1, "unchanged sync must retry durable unpublished work")
        XCTAssertEqual(try remoteNames(transport), completed.map(\.filename))
        _ = try await vault!.sync()
        XCTAssertEqual(transport.manifestAttempts, 1, "successful publication must clear the dirty marker")
    }
}
