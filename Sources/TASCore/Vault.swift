import Foundation

public struct TransferProgress: Sendable {
    public let message: String
    public let fraction: Double?
    public init(_ message: String, _ fraction: Double? = nil) { self.message = message; self.fraction = fraction }
}
public typealias ProgressHandler = @Sendable (TransferProgress) -> Void
public struct OperationResult: Sendable {
    public let message: String
    public let warning: String?
    public init(_ message: String, warning: String? = nil) { self.message = message; self.warning = warning }
}
public struct PendingUpload: Identifiable, Codable {
    public let id: Int64
    public let filename: String
    public let uploaded: Int
    public let total: Int
}
public struct SyncFolder: Identifiable, Codable {
    public let id: Int64
    public let path: String
    public let enabled: Bool
}

public actor Vault {
    public let directory: URL
    private let password: String
    private let lock: VaultLock
    private let config: Configuration
    private let db: Database
    private let transport: TelegramTransport
    private var busy = false
    private let publicationBoundary: (String) throws -> Void
    public init(directory: URL = Paths.dataDirectory, password: String) throws {
        self.directory = directory; self.password = password
        lock = try VaultLock(directory: directory)
        let loaded = try Configuration(directory: directory, password: password)
        config = loaded
        db = try Database(directory: directory, recover: { try ManifestJournal.recover(db: $0, config: loaded, password: password) })
        transport = Telegram(); publicationBoundary = { _ in }
    }
    init(directory: URL, password: String, transport: TelegramTransport, queryObserver: ((String) -> Void)? = nil, publicationBoundary: @escaping (String) throws -> Void = { _ in }) throws {
        self.directory = directory; self.password = password
        lock = try VaultLock(directory: directory)
        let loaded = try Configuration(directory: directory, password: password)
        config = loaded
        db = try Database(directory: directory, queryObserver: queryObserver) { try ManifestJournal.recover(db: $0, config: loaded, password: password, boundary: publicationBoundary) }
        self.transport = transport; self.publicationBoundary = publicationBoundary
    }
    public static func create(directory: URL = Paths.dataDirectory, password: String, token: String, chatID: String, endpoint: String? = nil) async throws {
        let lock = try VaultLock(directory: directory); defer { withExtendedLifetime(lock) {} }
        try Configuration.validate(id: "primary", token: token, chatID: chatID, endpoint: endpoint)
        var raw: JSON = ["id": "primary", "chatId": chatID]
        if let endpoint, !endpoint.isEmpty { raw["customApiUrl"] = endpoint }
        _ = try await Telegram().check(Bot(raw: raw, token: token))
        try Configuration.create(directory: directory, password: password, token: token, chatID: chatID, endpoint: endpoint)
    }
    private func begin() throws {
        try require(!busy, "已有任务运行，请等待完成或取消当前任务")
        try ManifestJournal.recover(db: db, config: config, password: password)
        busy = true
    }
    public func files(search: String = "", tag: String? = nil, includeDeleted: Bool = false) throws -> [StoredFile] { try db.files(search: search, tag: tag, includeDeleted: includeDeleted) }
    public func history(_ id: Int64) throws -> [FileVersion] { _ = try file(id); return try db.history(id) }
    public func statistics() throws -> VaultStatistics { try db.statistics() }
    public func bots() -> [BotInfo] { config.bots.map(\.info) }
    public func pending() throws -> [PendingUpload] {
        try db.rows("SELECT * FROM pending_uploads ORDER BY id").map { PendingUpload(id: number($0["id"]), filename: string($0["filename"]), uploaded: Int(number($0["uploaded_chunks"])), total: Int(number($0["total_chunks"]))) }
    }
    public func folders() throws -> [SyncFolder] {
        try db.rows("SELECT * FROM sync_folders ORDER BY id").map { SyncFolder(id: number($0["id"]), path: string($0["local_path"]), enabled: number($0["enabled"]) != 0) }
    }
    public func manifestDate() -> String? { (config.raw["remoteManifest"] as? JSON)?["createdAt"] as? String }
    private func file(_ id: Int64) throws -> StoredFile {
        guard let file = try db.files(includeDeleted: true).first(where: { $0.id == id }) else { throw TASError("文件不存在") }; return file
    }
    public func upload(_ source: URL, name: String? = nil, replace: Bool = false, message: String? = nil, progress: @escaping ProgressHandler = { _ in }) async throws -> OperationResult {
        try begin(); defer { busy = false }
        let id = try stage(source, name: name, replace: replace, message: message, progress: progress)
        guard id != 0 else { return OperationResult("内容未变化，已跳过") }
        try await finishUpload(id, progress: progress)
        return await publishResult("上传完成", progress: progress)
    }
    private func stage(_ source: URL, name: String?, replace: Bool, knownHash: String? = nil, message: String? = nil, sourceKind: String = "upload", progress: ProgressHandler) throws -> Int64 {
        let filename = try Paths.logical(name ?? source.lastPathComponent)
        let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        try require(properties.isRegularFile == true && properties.isSymbolicLink != true, "请选择普通文件")
        try require(try db.rows("SELECT id FROM pending_uploads WHERE filename=?", [filename]).isEmpty, "此路径有未完成上传，请先继续或清除")
        let existing = try db.rows("SELECT * FROM logical_files WHERE filename=?", [filename]).first
        try require(existing == nil || number(existing?["deleted"]) == 0, "文件已删除，请显式恢复历史版本")
        try require(replace || existing == nil, "同名文件已存在，请使用替换选项或修改逻辑路径")
        progress(TransferProgress("计算校验值 · \(filename)"))
        let hash = try knownHash ?? Crypto.hashFile(source); let compressed = Crypto.shouldCompress(filename)
        if existing != nil, try db.currentFileState(filename: filename)?.hash == hash { return 0 }
        let stagingRoot = ProcessInfo.processInfo.environment["TAS_TMP_DIR"].map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("tmp")
        let stage = try Paths.temporary(in: stagingRoot, prefix: "upload-"); try Paths.privateDirectory(stage)
        var persisted = false
        defer { if !persisted { try? FileManager.default.removeItem(at: stage) } }
        let encrypted = stage.appendingPathComponent("encrypted")
        progress(TransferProgress("加密文件 · \(filename)"))
        try Crypto.encryptFile(source, to: encrypted, password: password, compressed: compressed)
        try require(try Crypto.hashFile(source) == hash, "加密期间源文件发生变化，请重新上传")
        let input = try FileHandle(forReadingFrom: encrypted); defer { try? input.close() }
        let storedSize = try input.seekToEnd(); try input.seek(toOffset: 0)
        let total = Int((storedSize + UInt64(Crypto.chunkSize) - 1) / UInt64(Crypto.chunkSize))
        try require(total > 0 && total <= 65535, "文件超过分块数量限制")
        var chunks: [(URL, Int)] = []
        for index in 0..<total {
            try Task.checkCancellation()
            let data = try input.read(upToCount: Crypto.chunkSize) ?? Data()
            let path = stage.appendingPathComponent("chunk-\(index).bin")
            let output = try Paths.privateFile(path)
            try output.write(contentsOf: Crypto.header(index: index, total: total, compressed: compressed)); try output.write(contentsOf: data); try output.synchronize(); try output.close()
            chunks.append((path, data.count + Crypto.headerSize))
        }
        try input.close(); try FileManager.default.removeItem(at: encrypted)
        let id = try db.transaction {
            let id = try db.run("INSERT INTO pending_uploads(filename,file_path,hash,original_size,stored_size,compressed,total_chunks,temp_dir,message,source) VALUES(?,?,?,?,?,?,?,?,?,?)", [filename, source.path, hash, properties.fileSize ?? 0, Int64(storedSize), compressed ? 1 : 0, total, stage.path, message, sourceKind])
            for (index, chunk) in chunks.enumerated() { try db.run("INSERT INTO pending_chunks(pending_id,chunk_index,chunk_path,size) VALUES(?,?,?,?)", [id, index, chunk.0.path, chunk.1]) }
            return id
        }
        persisted = true; return id
    }
    private func finishUpload(_ id: Int64, progress: ProgressHandler) async throws {
        guard var upload = try db.rows("SELECT * FROM pending_uploads WHERE id=?", [id]).first else { throw TASError("未完成上传不存在") }
        // -1 is written only when migrating a schema with no compression column.
        var compression: Bool? = number(upload["compressed"]) == -1 ? nil : number(upload["compressed"]) != 0
        let chunks = try db.rows("SELECT * FROM pending_chunks WHERE pending_id=? ORDER BY chunk_index", [id])
        let total = Int(number(upload["total_chunks"]))
        try require(chunks.count == total && total > 0, "待上传分块记录不完整")
        for (index, chunk) in chunks.enumerated() {
            try require(number(chunk["chunk_index"]) == Int64(index), "待上传分块顺序不完整")
            var path = URL(fileURLWithPath: string(chunk["chunk_path"]))
            let uploaded = number(chunk["uploaded"]) != 0
            var temporary: URL?
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            if uploaded {
                try require(!string(chunk["message_id"]).isEmpty && !string(chunk["file_telegram_id"]).isEmpty, "已上传分块缺少 Telegram 信息")
                // Legacy uploads may have neither staged bytes nor a size column.
                // Downloading also validates the receipt's header instead of trusting a zero.
                let recovered = try Paths.temporary(in: directory.appendingPathComponent("tmp"), prefix: "receipt-")
                temporary = recovered
                try await transport.download(string(chunk["file_telegram_id"]), to: recovered, bot: config.owner(chunk["bot_id"] as? String))
                path = recovered
            }
            try require(FileManager.default.fileExists(atPath: path.path), "待上传分块丢失：\(path.lastPathComponent)")
            let input = try FileHandle(forReadingFrom: path)
            defer { try? input.close() }
            let header = try Crypto.parseHeader(input.read(upToCount: Crypto.headerSize) ?? Data())
            let size = try input.seekToEnd(); try input.close()
            try require(size > UInt64(Crypto.headerSize) && size <= UInt64(Int64.max), "待上传分块大小无效")
            try require(header.index == index && header.total == total, "待上传分块头与索引不匹配")
            if let compression { try require(header.compressed == compression, "待上传分块压缩标记不匹配") }
            else { compression = header.compressed }
            try require(number(chunk["size"]) == 0 || number(chunk["size"]) == Int64(size), "已上传分块大小与回执不匹配")
            try db.run("UPDATE pending_chunks SET size=? WHERE pending_id=? AND chunk_index=?", [Int64(size), id, index])
        }
        if number(upload["compressed"]) == -1 {
            let recovered = compression == true ? 1 : 0
            try db.run("UPDATE pending_uploads SET compressed=? WHERE id=?", [recovered, id])
            upload["compressed"] = recovered
        }
        for (index, chunk) in chunks.enumerated() where number(chunk["uploaded"]) == 0 {
            try Task.checkCancellation()
            progress(TransferProgress("上传 \(string(upload["filename"])) · \(index + 1)/\(total)", Double(index) / Double(total)))
            let bot = try config.select(string(upload["hash"]), index: index)
            let path = URL(fileURLWithPath: string(chunk["chunk_path"]))
            let result = try await transport.send(path, caption: "tas:c1:\(id):\(index + 1)/\(total)", bot: bot)
            try db.transaction {
                try db.run("UPDATE pending_chunks SET uploaded=1,message_id=?,file_telegram_id=?,bot_id=? WHERE pending_id=? AND chunk_index=?", [result.messageID, result.fileID, bot.id, id, index])
                try db.run("UPDATE pending_uploads SET uploaded_chunks=(SELECT COUNT(*) FROM pending_chunks WHERE pending_id=? AND uploaded=1) WHERE id=?", [id, id])
            }
            try? FileManager.default.removeItem(at: path)
        }
        let completed = try db.rows("SELECT * FROM pending_chunks WHERE pending_id=? ORDER BY chunk_index", [id])
        try require(completed.allSatisfy { number($0["uploaded"]) != 0 }, "上传尚未完成")
        try db.transaction {
            let previous = try db.rows("SELECT id FROM logical_files WHERE filename=?", [upload["filename"]]).first
            let stored = try checkedByteTotal(completed.map { number($0["size"]) - Int64(Crypto.headerSize) })
            let fileID = try db.run("INSERT INTO files(filename,hash,original_size,stored_size,chunks,compressed) VALUES(?,?,?,?,?,?)", [upload["filename"], upload["hash"], upload["original_size"], stored, total, upload["compressed"]])
            for chunk in completed { try db.run("INSERT INTO chunks(file_id,chunk_index,message_id,file_telegram_id,bot_id,size) VALUES(?,?,?,?,?,?)", [fileID, chunk["chunk_index"], chunk["message_id"], chunk["file_telegram_id"], chunk["bot_id"], chunk["size"]]) }
            let logicalID: Int64
            if let previous { logicalID = number(previous["id"]) }
            else { logicalID = try db.run("INSERT INTO logical_files(filename) VALUES(?)", [upload["filename"]]) }
            try db.appendVersion(logicalID, objectID: fileID, source: (upload["source"] as? String) ?? "upload", message: upload["message"] as? String)
            try db.run("INSERT OR IGNORE INTO manifest_dirty(id) VALUES(1)")
            try db.run("DELETE FROM pending_uploads WHERE id=?", [id])
        }
        // Only remove the directory when empty: legacy paths are never recursively deleted.
        if let path = upload["temp_dir"] as? String, (try? FileManager.default.contentsOfDirectory(atPath: path).isEmpty) == true { try? FileManager.default.removeItem(atPath: path) }
        progress(TransferProgress("上传完成 · \(string(upload["filename"]))", 1))
    }
    public func resume(progress: @escaping ProgressHandler = { _ in }) async throws -> OperationResult {
        try begin(); defer { busy = false }
        var completed = 0, failures: [String] = []
        for upload in try pending() {
            try Task.checkCancellation()
            do { try await finishUpload(upload.id, progress: progress); completed += 1 }
            catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(upload.filename)：\(error.localizedDescription)") }
        }
        let message = completed > 0 ? "已继续完成 \(completed) 个上传" : "没有完成新的上传"
        let needsPublication = try !db.rows("SELECT id FROM manifest_dirty WHERE id=1").isEmpty
        let result = needsPublication ? await publishResult(message, progress: progress) : OperationResult(message)
        let warnings = failures + [result.warning].compactMap { $0 }
        return OperationResult(result.message, warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
    }
    public func clearPending(_ id: Int64) async throws -> OperationResult {
        try begin(); defer { busy = false }
        let rows = try db.rows("SELECT * FROM pending_chunks WHERE pending_id=?", [id])
        var failures = 0
        for row in rows {
            if number(row["uploaded"]) != 0 { do { try await transport.delete(string(row["message_id"]), bot: config.owner(row["bot_id"] as? String)) } catch { failures += 1 } }
            // Never follow or recursively remove a path supplied by an old database.
            let path = string(row["chunk_path"])
            if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { try? FileManager.default.removeItem(atPath: path) }
        }
        try db.run("DELETE FROM pending_uploads WHERE id=?", [id])
        return OperationResult("已清除待上传任务", warning: failures > 0 ? "\(failures) 个 Telegram 消息未能删除" : nil)
    }
    public func download(_ id: Int64, to destination: URL, version: Int? = nil, progress: @escaping ProgressHandler = { _ in }) async throws {
        try begin(); defer { busy = false }
        let selected = try version.map { try db.versionFile(id, number: $0) } ?? file(id)
        try await restore(selected, to: destination, progress: progress)
    }
    private func restore(_ file: StoredFile, to destination: URL, progress: ProgressHandler) async throws {
        let chunks = try db.rows("SELECT * FROM chunks WHERE file_id=? ORDER BY chunk_index", [file.objectID])
        try require(chunks.count == file.chunks && !chunks.isEmpty, "文件分块索引不完整")
        let working = try Paths.temporary(in: directory.appendingPathComponent("tmp"), prefix: "download-")
        try Paths.privateDirectory(working); defer { try? FileManager.default.removeItem(at: working) }
        let encrypted = working.appendingPathComponent("encrypted")
        let output = try Paths.privateFile(encrypted); defer { try? output.close() }
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            try require(number(chunk["chunk_index"]) == Int64(index), "文件分块顺序错误")
            let bot = try config.owner(chunk["bot_id"] as? String)
            try require(number(chunk["size"]) <= 20 * 1024 * 1024 || bot.raw["customApiUrl"] != nil, "旧版大分块需要配置本地 Bot API 服务器下载")
            progress(TransferProgress("下载 \(file.filename) · \(index + 1)/\(chunks.count)", Double(index) / Double(chunks.count)))
            let part = working.appendingPathComponent("part-\(index)")
            try await transport.download(string(chunk["file_telegram_id"]), to: part, bot: bot)
            let input = try FileHandle(forReadingFrom: part); defer { try? input.close() }
            let header = try Crypto.parseHeader(input.read(upToCount: Crypto.headerSize) ?? Data())
            try require(header.index == index && header.total == chunks.count && header.compressed == file.compressed, "下载分块头与索引不匹配")
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
            try input.close(); try FileManager.default.removeItem(at: part)
        }
        try output.synchronize(); try output.close()
        progress(TransferProgress("解密并校验 · \(file.filename)"))
        let decrypted = working.appendingPathComponent("decrypted")
        try Crypto.decryptFile(encrypted, to: decrypted, password: password)
        try Paths.privateDirectory(destination.deletingLastPathComponent())
        let final = try Paths.temporary(in: destination.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: final) }
        if file.compressed { try Gzip.decompressFile(decrypted, to: final, limit: file.originalSize) }
        else { try copyPrivate(decrypted, final) }
        let size = try final.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        try require(Int64(size) == file.originalSize && (try Crypto.hashFile(final)) == file.hash, "文件大小或 SHA-256 校验失败；目标文件未改动")
        try Task.checkCancellation(); try Paths.atomicReplace(final, destination)
        progress(TransferProgress("下载完成 · \(file.filename)", 1))
    }
    private func publishResult(_ message: String, progress: ProgressHandler) async -> OperationResult {
        do { progress(TransferProgress("备份加密索引")); try await publishManifest(); return OperationResult(message) }
        catch { return OperationResult(message, warning: "本地索引已保存，但远端索引备份失败：\(error.localizedDescription)。请重试“备份索引”。") }
    }
    private func publishManifest() async throws {
        let snapshot = try db.manifest()
        _ = try Database.validatedManifest(snapshot)
        let payload = try Crypto.encrypt(Gzip.compress(jsonData(snapshot)), password: password)
        try require(payload.count <= Crypto.chunkSize, "加密索引超过单条恢复消息的大小限制")
        let path = try Paths.temporary(in: directory.appendingPathComponent("tmp"), prefix: "manifest-")
        try Paths.atomicWrite(payload, to: path); defer { try? FileManager.default.removeItem(at: path) }
        let bot = try config.select("manifest:\(string(snapshot["createdAt"]))", index: 0)
        let result = try await transport.send(path, caption: "tas:m1", bot: bot)
        let previous = config.raw["remoteManifest"] as? JSON
        config.raw["remoteManifest"] = ["version": 2, "botId": bot.id, "messageId": result.messageID, "fileId": result.fileID, "createdAt": snapshot["createdAt"]!, "files": (snapshot["files"] as? [JSON])?.count ?? 0, "chunks": (snapshot["chunks"] as? [JSON])?.count ?? 0]
        do { try config.save() } catch { config.raw["remoteManifest"] = previous; throw error }
        // Clear only after the recovery pointer is durable. A crash before this
        // write may repeat a backup, but cannot lose unpublished local content.
        try db.run("DELETE FROM manifest_dirty WHERE id=1")
        if let previous, let owner = try? config.owner(previous["botId"] as? String) { try? await transport.delete(string(previous["messageId"]), bot: owner) }
    }
    /// Capture an intended mutation, then publish from a durable outbox rather
    /// than holding an uncommitted SQLite transaction across a network request.
    private func publishMutation() async throws {
        let snapshot: JSON
        do {
            snapshot = try db.manifest(includeShares: true)
            _ = try Database.validatedManifest(snapshot)
            try db.script("ROLLBACK")
        } catch { try? db.script("ROLLBACK"); throw error }
        let previous = config.raw["remoteManifest"] as? JSON
        var record: JSON = ["phase": "prepared", "snapshot": snapshot,
                            "owners": try ManifestJournal.owners(config).base64EncodedString()]
        if let previous { record["previousPointer"] = previous }
        try ManifestJournal.store(record, db: db, password: password)
        try publicationBoundary("prepared")
        let payload = try Crypto.encrypt(Gzip.compress(jsonData(snapshot)), password: password)
        try require(payload.count <= Crypto.chunkSize, "加密索引超过单条恢复消息的大小限制")
        let path = try Paths.temporary(in: directory.appendingPathComponent("tmp"), prefix: "manifest-")
        try Paths.atomicWrite(payload, to: path); defer { try? FileManager.default.removeItem(at: path) }
        let bot = try config.select("manifest:\(string(snapshot["createdAt"]))", index: 0)
        let result = try await transport.send(path, caption: "tas:m1", bot: bot)
        try publicationBoundary("uploaded")
        record["pointer"] = ["version": 2, "botId": bot.id, "messageId": result.messageID,
                             "fileId": result.fileID, "createdAt": snapshot["createdAt"]!,
                             "files": (snapshot["files"] as? [JSON])?.count ?? 0,
                             "chunks": (snapshot["chunks"] as? [JSON])?.count ?? 0]
        record["phase"] = "uploaded"
        try ManifestJournal.store(record, db: db, password: password)
        try publicationBoundary("receiptStored")
        try ManifestJournal.recover(db: db, config: config, password: password, boundary: publicationBoundary)
        // Only now may the previous recovery message be removed. Interrupted
        // cleanup leaks unused messages, never references to live content.
        if let previous, let owner = try? config.owner(previous["botId"] as? String) {
            try? await transport.delete(string(previous["messageId"]), bot: owner)
        }
    }
    public func backupIndex() async throws -> OperationResult {
        try begin(); defer { busy = false }; try await publishManifest(); return OperationResult("远端加密索引备份完成")
    }
    public func rebuildIndex() async throws -> OperationResult {
        try begin(); defer { busy = false }
        try require(try pending().isEmpty, "存在待上传任务，不能重建索引")
        guard let pointer = config.raw["remoteManifest"] as? JSON, !string(pointer["fileId"]).isEmpty else { throw TASError("配置中没有远端索引恢复指针") }
        let path = try Paths.temporary(in: directory.appendingPathComponent("tmp"), prefix: "manifest-")
        defer { try? FileManager.default.removeItem(at: path) }
        try await transport.download(string(pointer["fileId"]), to: path, bot: config.owner(pointer["botId"] as? String))
        let encryptedSize = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        try require(encryptedSize <= Crypto.chunkSize, "远端索引超过大小限制")
        let manifest = try jsonObject(Gzip.decompress(Crypto.decrypt(Data(contentsOf: path), password: password)))
        let backup = directory.appendingPathComponent("index-before-rebuild-\(UUID().uuidString).db")
        try db.backup(to: backup); try db.importManifest(manifest)
        return OperationResult("索引恢复完成，原索引已备份为 \(backup.lastPathComponent)")
    }
    public func delete(_ id: Int64, hard: Bool = false) async throws -> OperationResult {
        try begin(); defer { busy = false }
        let target = try file(id); try requireNoPending(target.filename)
        try require(!hard || target.deleted, "请先软删除文件，再永久清除")
        var chunks: [JSON] = []
        try db.script("BEGIN IMMEDIATE; PRAGMA defer_foreign_keys=ON")
        do {
            if hard {
                let objects = try db.rows("SELECT DISTINCT object_id FROM file_versions WHERE file_id=?", [id])
                try db.run("DELETE FROM tags WHERE file_id=?", [id])
                try db.run("DELETE FROM shares WHERE file_id=?", [id])
                try db.run("DELETE FROM logical_files WHERE id=?", [id])
                for object in objects {
                    let objectID = number(object["object_id"])
                    if try db.rows("SELECT id FROM file_versions WHERE object_id=?", [objectID]).isEmpty {
                        chunks += try db.rows("SELECT * FROM chunks WHERE file_id=?", [objectID])
                        try db.run("DELETE FROM files WHERE id=?", [objectID])
                    }
                }
                // A shared Telegram message must survive even if its object was purged.
                let retained = try db.rows("SELECT bot_id,message_id FROM chunks")
                chunks = chunks.filter { candidate in
                    !retained.contains { other in
                        guard string(other["message_id"]) == string(candidate["message_id"]) else { return false }
                        // NULL means the legacy primary owner. Bot aliases in the same
                        // endpoint/chat address the same message, regardless of token.
                        // Unknown ownership cannot establish that deletion is safe.
                        guard let a = try? config.owner(candidate["bot_id"] as? String),
                              let b = try? config.owner(other["bot_id"] as? String) else { return true }
                        return a.endpoint == b.endpoint && a.chatID == b.chatID
                    }
                }
            } else {
                try db.run("UPDATE logical_files SET deleted=1,updated_at=? WHERE id=?", [timestamp(), id])
            }
            try await publishMutation()
        } catch { try? db.script("ROLLBACK"); throw error }
        var failures = 0
        for chunk in chunks { do { try await transport.delete(string(chunk["message_id"]), bot: config.owner(chunk["bot_id"] as? String)) } catch { failures += 1 } }
        return OperationResult("已\(hard ? "永久清除" : "删除") \(target.filename)", warning: failures > 0 ? "Telegram 未能删除 \(failures) 条分块消息" : nil)
    }
    private func requireNoPending(_ filename: String) throws {
        try require(try db.rows("SELECT id FROM pending_uploads WHERE filename=?", [filename]).isEmpty, "此路径有未完成上传，请先继续或清除")
    }
    public func restoreVersion(_ id: Int64, version: Int, message: String? = nil, progress: @escaping ProgressHandler = { _ in }) async throws -> OperationResult {
        try begin(); defer { busy = false }
        let target = try file(id); try requireNoPending(target.filename)
        let selected = try db.versionFile(id, number: version)
        let original = try db.history(id).first { $0.number == version }!
        try db.script("BEGIN IMMEDIATE")
        do {
            try db.appendVersion(id, objectID: selected.objectID, source: "restore", message: message, restoredFrom: original.id)
            try db.run("UPDATE logical_files SET deleted=0,sync_paused=1 WHERE id=?", [id])
            progress(TransferProgress("备份恢复后的历史索引"))
            try await publishMutation()
        } catch { try? db.script("ROLLBACK"); throw error }
        return OperationResult("已恢复版本 \(version)，自动同步已暂停")
    }
    public func resumeSync(_ id: Int64) async throws -> OperationResult {
        try begin(); defer { busy = false }
        let target = try file(id); try require(!target.deleted, "已删除文件不能恢复同步")
        try requireNoPending(target.filename)
        try db.script("BEGIN IMMEDIATE")
        do {
            try db.run("UPDATE logical_files SET sync_paused=0 WHERE id=?", [id])
            try await publishMutation()
        } catch { try? db.script("ROLLBACK"); throw error }
        return OperationResult("已恢复自动同步")
    }
    public func tag(_ id: Int64, value: String, remove: Bool = false) async throws -> OperationResult {
        try begin(); defer { busy = false }; _ = try file(id)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try require(!value.isEmpty && value.count <= 128, "标签需为 1–128 个字符")
        if remove { try db.run("DELETE FROM tags WHERE file_id=? AND tag=?", [id, value]) }
        else { try db.run("INSERT OR IGNORE INTO tags(file_id,tag) VALUES(?,?)", [id, value]) }
        return await publishResult("标签已更新", progress: { _ in })
    }
    public func verify(deep: Bool = false, allVersions: Bool = false, progress: @escaping ProgressHandler = { _ in }) async throws -> OperationResult {
        try begin(); defer { busy = false }; var problems: [String] = []
        let files = try allVersions ? db.allVersionObjects() : db.files()
        for (index, file) in files.enumerated() {
            try Task.checkCancellation(); progress(TransferProgress("检查 \(file.filename)", Double(index) / Double(max(1, files.count))))
            do {
                if deep {
                    let temporary = try Paths.temporary(in: directory.appendingPathComponent("tmp"), prefix: "verify-"); defer { try? FileManager.default.removeItem(at: temporary) }
                    try await restore(file, to: temporary, progress: progress)
                } else {
                    let chunks = try db.rows("SELECT * FROM chunks WHERE file_id=? ORDER BY chunk_index", [file.objectID])
                    try require(chunks.count == file.chunks, "分块索引不完整")
                    for (i, chunk) in chunks.enumerated() {
                        try require(number(chunk["chunk_index"]) == Int64(i), "分块顺序错误")
                        _ = try await transport.metadata(string(chunk["file_telegram_id"]), bot: config.owner(chunk["bot_id"] as? String))
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { problems.append("\(file.filename)：\(error.localizedDescription)") }
        }
        return OperationResult("已检查 \(files.count) 个文件", warning: problems.isEmpty ? nil : problems.joined(separator: "\n"))
    }
    public func checkBots() async throws -> OperationResult {
        try begin(); defer { busy = false }
        for bot in config.bots { _ = try await transport.check(bot) }
        try require(try db.rows("PRAGMA integrity_check").allSatisfy { string($0["integrity_check"]) == "ok" }, "SQLite 完整性检查失败")
        return OperationResult("机器人连接与本地索引检查通过")
    }
    public func addBot(id: String, token: String, chatID: String, endpoint: String? = nil) async throws {
        try begin(); defer { busy = false }
        try Configuration.validate(id: id, token: token, chatID: chatID, endpoint: endpoint)
        try require(!config.bots.contains { $0.id == id }, "此机器人编号已存在")
        var raw: JSON = ["id": id, "chatId": chatID, "enabled": true, "createdAt": timestamp(), "encryptedBotToken": try Crypto.encrypt(Data(token.utf8), password: password).base64EncodedString()]
        if let endpoint, !endpoint.isEmpty { raw["customApiUrl"] = endpoint }
        let username = try await transport.check(Bot(raw: raw, token: token)); raw["username"] = username
        try config.saveBots(password: password, replacing: config.bots + [Bot(raw: raw, token: token)])
    }
    public func updateBot(_ id: String, enabled: Bool? = nil, endpoint: String? = nil, remove: Bool = false) throws {
        try begin(); defer { busy = false }
        guard let index = config.bots.firstIndex(where: { $0.id == id }) else { throw TASError("机器人不存在") }
        var proposed = config.bots
        if remove {
            let legacy = id == "primary" || config.bots.count == 1
            let count = try db.rows("SELECT id FROM chunks WHERE bot_id=? OR (?=1 AND bot_id IS NULL) UNION ALL SELECT id FROM pending_chunks WHERE bot_id=? OR (?=1 AND uploaded=1 AND bot_id IS NULL)", [id, legacy ? 1 : 0, id, legacy ? 1 : 0]).count
            let pointer = config.raw["remoteManifest"] as? JSON
            let manifestOwner = pointer.flatMap { try? config.owner($0["botId"] as? String).id }
            try require(count == 0 && manifestOwner != id, "仍有分块或恢复索引依赖此机器人；可以停用，但不能移除")
            proposed.remove(at: index)
        } else {
            if let enabled { proposed[index].raw["enabled"] = enabled }
            if let endpoint { try Configuration.validate(id: id, token: proposed[index].token, chatID: proposed[index].chatID, endpoint: endpoint); proposed[index].raw["customApiUrl"] = endpoint.isEmpty ? nil : endpoint }
        }
        try require(proposed.contains(where: \.enabled), "必须保留至少一个启用的机器人")
        try config.saveBots(password: password, replacing: proposed)
    }
    private static func canonicalPath(_ url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else { throw TASError("无法解析路径：\(url.path)") }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    public func addFolder(_ url: URL) throws {
        try begin(); defer { busy = false }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        try require(values.isDirectory == true && values.isSymbolicLink != true, "请选择普通文件夹")
        let root = try Self.canonicalPath(url)
        let vaultRoot = try Self.canonicalPath(directory)
        try require(root != vaultRoot && !root.hasPrefix(vaultRoot + "/"), "不能将文件库数据目录作为同步源")
        try db.run("INSERT OR IGNORE INTO sync_folders(local_path) VALUES(?)", [url.standardizedFileURL.path])
    }
    public func removeFolder(_ id: Int64) throws { try begin(); defer { busy = false }; try db.run("DELETE FROM sync_folders WHERE id=?", [id]) }
    /// Snapshot sync never mirrors deletions. Run periodically from the UI or CLI watch loop.
    public func sync(progress: @escaping ProgressHandler = { _ in }) async throws -> OperationResult {
        try begin(); defer { busy = false }; var changed = 0, failures: [String] = []
        var candidates: [(url: URL, logical: String, folderID: Int64, mtime: Int64, size: Int64)] = []
        for folder in try folders() where folder.enabled {
            let root = URL(fileURLWithPath: folder.path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            let rootPath: String
            do { rootPath = try Self.canonicalPath(root) }
            catch { failures.append("\(root.path)：\(error.localizedDescription)"); continue }
            let vaultRoot = try Self.canonicalPath(directory)
            let temporaryRoot = ProcessInfo.processInfo.environment["TAS_TMP_DIR"].flatMap { try? Self.canonicalPath(URL(fileURLWithPath: $0)) }
            var directories = [root]
            while let current = directories.popLast() {
                try Task.checkCancellation()
                let entries: [URL]
                do {
                    entries = try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
                } catch { failures.append("\(current.path)：\(error.localizedDescription)"); continue }
                for url in entries {
                    try Task.checkCancellation()
                    do {
                        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
                        if attributes.isSymbolicLink == true { continue }
                        let path = try Self.canonicalPath(url)
                        if [vaultRoot, temporaryRoot].compactMap({ $0 }).contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
                        if attributes.isDirectory == true { directories.append(url); continue }
                        guard attributes.isRegularFile == true else { continue }
                        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                        try require(path.hasPrefix(prefix), "同步文件不在所选目录内")
                        let relative = String(path.dropFirst(prefix.count))
                        let logical = try Paths.logical(relative)
                        let mtime = Int64((attributes.contentModificationDate ?? Date.distantPast).timeIntervalSince1970 * 1000)
                        candidates.append((url, logical, folder.id, mtime, Int64(attributes.fileSize ?? -1)))
                    } catch is CancellationError { throw CancellationError() }
                    catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
                }
            }
        }
        let grouped = Dictionary(grouping: candidates, by: \.logical)
        let conflicts = grouped.filter { $0.value.count > 1 }.keys.sorted()
        try require(conflicts.isEmpty, "同步路径冲突（未上传任何文件）：" + conflicts.joined(separator: ", "))
        try db.adoptLegacyObjects()
        for candidate in candidates {
            do {
                try Task.checkCancellation()
                let current = try db.currentFileState(filename: candidate.logical)
                if let current, current.deleted || current.syncPaused { continue }
                try requireNoPending(candidate.logical)
                if let current,
                   let state = try db.rows("SELECT * FROM sync_state WHERE folder_id=? AND relative_path=?", [candidate.folderID, candidate.logical]).first,
                   number(state["mtime"]) == candidate.mtime,
                   string(state["file_hash"]) == current.hash,
                   current.originalSize == candidate.size,
                   try db.rows("SELECT id FROM chunks WHERE file_id=?", [current.objectID]).count == current.chunks { continue }
                let hash = try Crypto.hashFile(candidate.url)
                if current?.hash != hash {
                    let id = try stage(candidate.url, name: candidate.logical, replace: true, knownHash: hash, sourceKind: "sync", progress: progress)
                    if id != 0 { try await finishUpload(id, progress: progress); changed += 1 }
                }
                try db.run("INSERT INTO sync_state(folder_id,relative_path,file_hash,mtime,synced_at) VALUES(?,?,?,?,?) ON CONFLICT(folder_id,relative_path) DO UPDATE SET file_hash=excluded.file_hash,mtime=excluded.mtime,synced_at=excluded.synced_at", [candidate.folderID, candidate.logical, hash, candidate.mtime, timestamp()])
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(candidate.logical)：\(error.localizedDescription)") }
        }
        let message = changed > 0 ? "同步完成，更新 \(changed) 个文件" : "同步完成，没有文件需要更新"
        let needsPublication = try !db.rows("SELECT id FROM manifest_dirty WHERE id=1").isEmpty
        let result = needsPublication ? await publishResult(message, progress: progress) : OperationResult(message)
        let warnings = failures + [result.warning].compactMap { $0 }
        return OperationResult(result.message, warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
    }
    public func restoreAll(to root: URL, progress: @escaping ProgressHandler = { _ in }) async throws -> OperationResult {
        try begin(); defer { busy = false }; let files = try db.files()
        for file in files { try await restore(file, to: Paths.contained(file.filename, in: root), progress: progress) }
        return OperationResult("已恢复 \(files.count) 个文件")
    }
}
