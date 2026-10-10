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
    public init(directory: URL = Paths.dataDirectory, password: String) throws {
        self.directory = directory; self.password = password
        lock = try VaultLock(directory: directory)
        config = try Configuration(directory: directory, password: password)
        db = try Database(directory: directory); transport = Telegram()
    }
    init(directory: URL, password: String, transport: TelegramTransport) throws {
        self.directory = directory; self.password = password
        lock = try VaultLock(directory: directory)
        config = try Configuration(directory: directory, password: password)
        db = try Database(directory: directory); self.transport = transport
    }
    public static func create(directory: URL = Paths.dataDirectory, password: String, token: String, chatID: String, endpoint: String? = nil) async throws {
        let lock = try VaultLock(directory: directory); defer { withExtendedLifetime(lock) {} }
        try Configuration.validate(id: "primary", token: token, chatID: chatID, endpoint: endpoint)
        var raw: JSON = ["id": "primary", "chatId": chatID]
        if let endpoint, !endpoint.isEmpty { raw["customApiUrl"] = endpoint }
        _ = try await Telegram().check(Bot(raw: raw, token: token))
        try Configuration.create(directory: directory, password: password, token: token, chatID: chatID, endpoint: endpoint)
    }
    private func begin() throws { try require(!busy, "已有任务运行，请等待完成或取消当前任务"); busy = true }
    public func files(search: String = "", tag: String? = nil) throws -> [StoredFile] { try db.files(search: search, tag: tag) }
    public func bots() -> [BotInfo] { config.bots.map(\.info) }
    public func pending() throws -> [PendingUpload] {
        try db.rows("SELECT * FROM pending_uploads ORDER BY id").map { PendingUpload(id: number($0["id"]), filename: string($0["filename"]), uploaded: Int(number($0["uploaded_chunks"])), total: Int(number($0["total_chunks"]))) }
    }
    public func folders() throws -> [SyncFolder] {
        try db.rows("SELECT * FROM sync_folders ORDER BY id").map { SyncFolder(id: number($0["id"]), path: string($0["local_path"]), enabled: number($0["enabled"]) != 0) }
    }
    public func manifestDate() -> String? { (config.raw["remoteManifest"] as? JSON)?["createdAt"] as? String }
    private func file(_ id: Int64) throws -> StoredFile {
        guard let row = try db.rows("SELECT * FROM files WHERE id=?", [id]).first else { throw TASError("文件不存在") }; return StoredFile(row)
    }
    public func upload(_ source: URL, name: String? = nil, replace: Bool = false, progress: @escaping ProgressHandler = { _ in }) async throws -> OperationResult {
        try begin(); defer { busy = false }
        let id = try stage(source, name: name, replace: replace, progress: progress)
        try await finishUpload(id, progress: progress)
        return await publishResult("上传完成", progress: progress)
    }
    private func stage(_ source: URL, name: String?, replace: Bool, knownHash: String? = nil, progress: ProgressHandler) throws -> Int64 {
        let filename = try Paths.logical(name ?? source.lastPathComponent)
        let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        try require(properties.isRegularFile == true && properties.isSymbolicLink != true, "请选择普通文件")
        try require(try db.rows("SELECT id FROM pending_uploads WHERE filename=?", [filename]).isEmpty, "此路径有未完成上传，请先继续或清除")
        let existing = try db.rows("SELECT * FROM files WHERE filename=?", [filename]).first
        try require(replace || existing == nil, "同名文件已存在，请使用替换选项或修改逻辑路径")
        progress(TransferProgress("计算校验值 · \(filename)"))
        let hash = try knownHash ?? Crypto.hashFile(source); let compressed = Crypto.shouldCompress(filename)
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
            let id = try db.run("INSERT INTO pending_uploads(filename,file_path,hash,original_size,stored_size,compressed,total_chunks,temp_dir) VALUES(?,?,?,?,?,?,?,?)", [filename, source.path, hash, properties.fileSize ?? 0, Int64(storedSize), compressed ? 1 : 0, total, stage.path])
            for (index, chunk) in chunks.enumerated() { try db.run("INSERT INTO pending_chunks(pending_id,chunk_index,chunk_path,size) VALUES(?,?,?,?)", [id, index, chunk.0.path, chunk.1]) }
            return id
        }
        persisted = true; return id
    }
    private func finishUpload(_ id: Int64, progress: ProgressHandler) async throws {
        guard let upload = try db.rows("SELECT * FROM pending_uploads WHERE id=?", [id]).first else { throw TASError("未完成上传不存在") }
        let chunks = try db.rows("SELECT * FROM pending_chunks WHERE pending_id=? ORDER BY chunk_index", [id])
        let total = Int(number(upload["total_chunks"]))
        try require(chunks.count == total && total > 0, "待上传分块记录不完整")
        for (index, chunk) in chunks.enumerated() {
            try require(number(chunk["chunk_index"]) == Int64(index), "待上传分块顺序不完整")
            if number(chunk["uploaded"]) != 0 {
                try require(!string(chunk["message_id"]).isEmpty && !string(chunk["file_telegram_id"]).isEmpty, "已上传分块缺少 Telegram 信息"); continue
            }
            let path = URL(fileURLWithPath: string(chunk["chunk_path"]))
            try require(FileManager.default.fileExists(atPath: path.path), "待上传分块丢失：\(path.lastPathComponent)")
            let input = try FileHandle(forReadingFrom: path)
            let header = try Crypto.parseHeader(input.read(upToCount: Crypto.headerSize) ?? Data()); try input.close()
            try require(header.index == index && header.total == total && header.compressed == (number(upload["compressed"]) != 0), "待上传分块头与索引不匹配")
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
            let previous = try db.rows("SELECT id FROM files WHERE filename=?", [upload["filename"]])
            let stored = number(upload["stored_size"]) > 0 ? number(upload["stored_size"]) : max(0, completed.reduce(Int64(0)) { $0 + number($1["size"]) } - Int64(total * Crypto.headerSize))
            let fileID = try db.run("INSERT INTO files(filename,hash,original_size,stored_size,chunks,compressed) VALUES(?,?,?,?,?,?)", [upload["filename"], upload["hash"], upload["original_size"], stored, total, upload["compressed"]])
            for chunk in completed { try db.run("INSERT INTO chunks(file_id,chunk_index,message_id,file_telegram_id,bot_id,size) VALUES(?,?,?,?,?,?)", [fileID, chunk["chunk_index"], chunk["message_id"], chunk["file_telegram_id"], chunk["bot_id"], chunk["size"]]) }
            for old in previous {
                try db.run("INSERT OR IGNORE INTO tags(file_id,tag,created_at) SELECT ?,tag,created_at FROM tags WHERE file_id=?", [fileID, old["id"]])
                try db.run("UPDATE shares SET file_id=? WHERE file_id=?", [fileID, old["id"]])
                try db.run("DELETE FROM files WHERE id=?", [old["id"]])
            }
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
        let result = completed > 0 ? await publishResult("已继续完成 \(completed) 个上传", progress: progress) : OperationResult("没有完成新的上传")
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
    public func download(_ id: Int64, to destination: URL, progress: @escaping ProgressHandler = { _ in }) async throws {
        try begin(); defer { busy = false }
        try await restore(file(id), to: destination, progress: progress)
    }
    private func restore(_ file: StoredFile, to destination: URL, progress: ProgressHandler) async throws {
        let chunks = try db.rows("SELECT * FROM chunks WHERE file_id=? ORDER BY chunk_index", [file.id])
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
        let payload = try Crypto.encrypt(Gzip.compress(jsonData(snapshot)), password: password)
        try require(payload.count <= Crypto.chunkSize, "加密索引超过单条恢复消息的大小限制")
        let path = try Paths.temporary(in: directory.appendingPathComponent("tmp"), prefix: "manifest-")
        try Paths.atomicWrite(payload, to: path); defer { try? FileManager.default.removeItem(at: path) }
        let bot = try config.select("manifest:\(string(snapshot["createdAt"]))", index: 0)
        let result = try await transport.send(path, caption: "tas:m1", bot: bot)
        let previous = config.raw["remoteManifest"] as? JSON
        config.raw["remoteManifest"] = ["version": 1, "botId": bot.id, "messageId": result.messageID, "fileId": result.fileID, "createdAt": snapshot["createdAt"]!, "files": (snapshot["files"] as? [JSON])?.count ?? 0, "chunks": (snapshot["chunks"] as? [JSON])?.count ?? 0]
        do { try config.save() } catch { config.raw["remoteManifest"] = previous; throw error }
        if let previous, let owner = try? config.owner(previous["botId"] as? String) { try? await transport.delete(string(previous["messageId"]), bot: owner) }
    }
    public func backupIndex() async throws -> OperationResult {
        try begin(); defer { busy = false }; try await publishManifest(); return OperationResult("远端加密索引备份完成")
    }
    public func rebuildIndex() async throws -> OperationResult {
        try begin(); defer { busy = false }
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
        let target = try file(id); let before = try db.manifest(includeShares: true)
        let chunks = try db.rows("SELECT * FROM chunks WHERE file_id=?", [id])
        try db.run("DELETE FROM files WHERE id=?", [id])
        do { try await publishManifest() } catch { try db.importManifest(before); throw error }
        var failures = 0
        if hard { for chunk in chunks { do { try await transport.delete(string(chunk["message_id"]), bot: config.owner(chunk["bot_id"] as? String)) } catch { failures += 1 } } }
        return OperationResult("已删除 \(target.filename)", warning: failures > 0 ? "Telegram 未能删除 \(failures) 条分块消息" : nil)
    }
    public func tag(_ id: Int64, value: String, remove: Bool = false) async throws -> OperationResult {
        try begin(); defer { busy = false }; _ = try file(id)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try require(!value.isEmpty && value.count <= 128, "标签需为 1–128 个字符")
        if remove { try db.run("DELETE FROM tags WHERE file_id=? AND tag=?", [id, value]) }
        else { try db.run("INSERT OR IGNORE INTO tags(file_id,tag) VALUES(?,?)", [id, value]) }
        return await publishResult("标签已更新", progress: { _ in })
    }
    public func verify(deep: Bool = false, progress: @escaping ProgressHandler = { _ in }) async throws -> OperationResult {
        try begin(); defer { busy = false }; var problems: [String] = []
        let files = try db.files()
        for (index, file) in files.enumerated() {
            try Task.checkCancellation(); progress(TransferProgress("检查 \(file.filename)", Double(index) / Double(max(1, files.count))))
            do {
                if deep {
                    let temporary = try Paths.temporary(in: directory.appendingPathComponent("tmp"), prefix: "verify-"); defer { try? FileManager.default.removeItem(at: temporary) }
                    try await restore(file, to: temporary, progress: progress)
                } else {
                    let chunks = try db.rows("SELECT * FROM chunks WHERE file_id=? ORDER BY chunk_index", [file.id])
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
        let previous = config.bots; config.bots.append(Bot(raw: raw, token: token))
        do { try config.saveBots(password: password) } catch { config.bots = previous; throw error }
    }
    public func updateBot(_ id: String, enabled: Bool? = nil, endpoint: String? = nil, remove: Bool = false) throws {
        try begin(); defer { busy = false }
        guard let index = config.bots.firstIndex(where: { $0.id == id }) else { throw TASError("机器人不存在") }
        let previous = config.bots
        if remove {
            let legacy = id == "primary" || config.bots.count == 1
            let count = try db.rows("SELECT id FROM chunks WHERE bot_id=? OR (?=1 AND bot_id IS NULL) UNION ALL SELECT id FROM pending_chunks WHERE bot_id=? OR (?=1 AND uploaded=1 AND bot_id IS NULL)", [id, legacy ? 1 : 0, id, legacy ? 1 : 0]).count
            let pointer = config.raw["remoteManifest"] as? JSON
            let manifestOwner = pointer.flatMap { try? config.owner($0["botId"] as? String).id }
            try require(count == 0 && manifestOwner != id, "仍有分块或恢复索引依赖此机器人；可以停用，但不能移除")
            config.bots.remove(at: index)
        } else {
            if let enabled { config.bots[index].raw["enabled"] = enabled }
            if let endpoint { try Configuration.validate(id: id, token: config.bots[index].token, chatID: config.bots[index].chatID, endpoint: endpoint); config.bots[index].raw["customApiUrl"] = endpoint.isEmpty ? nil : endpoint }
        }
        do { try require(config.bots.contains(where: \.enabled), "必须保留至少一个启用的机器人"); try config.saveBots(password: password) }
        catch { config.bots = previous; throw error }
    }
    public func addFolder(_ url: URL) throws {
        try begin(); defer { busy = false }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        try require(values.isDirectory == true && values.isSymbolicLink != true, "请选择普通文件夹")
        try db.run("INSERT OR IGNORE INTO sync_folders(local_path) VALUES(?)", [url.standardizedFileURL.path])
    }
    public func removeFolder(_ id: Int64) throws { try begin(); defer { busy = false }; try db.run("DELETE FROM sync_folders WHERE id=?", [id]) }
    /// Snapshot sync never mirrors deletions. Run periodically from the UI or CLI watch loop.
    public func sync(progress: @escaping ProgressHandler = { _ in }) async throws -> OperationResult {
        try begin(); defer { busy = false }; var changed = 0, failures: [String] = []
        for folder in try folders() where folder.enabled {
            let root = URL(fileURLWithPath: folder.path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { url, error in failures.append("\(url.path)：\(error.localizedDescription)"); return true }) else { failures.append("无法扫描 \(folder.path)"); continue }
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                do {
                    let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
                    if attributes.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    let vaultRoot = directory.resolvingSymlinksInPath().standardizedFileURL.path
                    let temporaryRoot = ProcessInfo.processInfo.environment["TAS_TMP_DIR"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
                    if [vaultRoot, temporaryRoot].compactMap({ $0 }).contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) { enumerator.skipDescendants(); continue }
                    guard attributes.isRegularFile == true else { continue }
                    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                    try require(url.path.hasPrefix(prefix), "同步文件不在所选目录内")
                    let relative = String(url.path.dropFirst(prefix.count))
                    let logical = try Paths.logical(relative)
                    let mtime = Int64((attributes.contentModificationDate ?? Date.distantPast).timeIntervalSince1970 * 1000)
                    if let state = try db.rows("SELECT * FROM sync_state WHERE folder_id=? AND relative_path=?", [folder.id, relative]).first,
                       number(state["mtime"]) == mtime,
                       let stored = try db.rows("SELECT * FROM files WHERE filename=? AND hash=?", [logical, state["file_hash"]]).first,
                       number(stored["original_size"]) == Int64(attributes.fileSize ?? -1),
                       try db.rows("SELECT id FROM chunks WHERE file_id=?", [stored["id"]]).count == Int(number(stored["chunks"])) { continue }
                    let hash = try Crypto.hashFile(url)
                    if try db.rows("SELECT id FROM files WHERE filename=? AND hash=?", [logical, hash]).isEmpty {
                        let id = try stage(url, name: logical, replace: true, knownHash: hash, progress: progress)
                        try await finishUpload(id, progress: progress); changed += 1
                    }
                    try db.run("INSERT INTO sync_state(folder_id,relative_path,file_hash,mtime,synced_at) VALUES(?,?,?,?,?) ON CONFLICT(folder_id,relative_path) DO UPDATE SET file_hash=excluded.file_hash,mtime=excluded.mtime,synced_at=excluded.synced_at", [folder.id, relative, hash, mtime, timestamp()])
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
        }
        let result = changed > 0 ? await publishResult("同步完成，更新 \(changed) 个文件", progress: progress) : OperationResult("同步完成，没有文件需要更新")
        let warnings = failures + [result.warning].compactMap { $0 }
        return OperationResult(result.message, warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
    }
    public func restoreAll(to root: URL, progress: @escaping ProgressHandler = { _ in }) async throws -> OperationResult {
        try begin(); defer { busy = false }; let files = try db.files()
        for file in files { try await restore(file, to: Paths.contained(file.filename, in: root), progress: progress) }
        return OperationResult("已恢复 \(files.count) 个文件")
    }
}
