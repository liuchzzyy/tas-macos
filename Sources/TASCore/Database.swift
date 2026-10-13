import Foundation
import CSQLite

public struct StoredFile: Identifiable, Codable, Hashable, Sendable {
    public let id: Int64
    public let filename: String
    public let hash: String
    public let originalSize: Int64
    public let storedSize: Int64
    public let chunks: Int
    public let compressed: Bool
    public let createdAt: String
    public var tags: [String]
    public let versionNumber: Int
    public let versionCount: Int
    public let updatedAt: String
    public let deleted: Bool
    public let syncPaused: Bool
    let objectID: Int64
    let keyID: String
    init(_ row: JSON, tags: [String] = []) {
        id = number(row["id"]); filename = string(row["filename"]); hash = string(row["hash"])
        originalSize = number(row["original_size"]); storedSize = number(row["stored_size"])
        chunks = Int(number(row["chunks"])); compressed = number(row["compressed"]) != 0
        createdAt = string(row["created_at"]); self.tags = tags
        objectID = row["object_id"] == nil ? id : number(row["object_id"])
        keyID = string(row["key_id"])
        versionNumber = Int(number(row["version_number"] ?? 1)); versionCount = Int(number(row["version_count"] ?? 1))
        updatedAt = string(row["updated_at"]); deleted = number(row["deleted"]) != 0; syncPaused = number(row["sync_paused"]) != 0
    }
}

/// Only the fields required to decide whether a sync candidate needs uploading.
struct CurrentFileState {
    let hash: String
    let originalSize: Int64
    let objectID: Int64
    let chunks: Int
    let deleted: Bool
    let syncPaused: Bool
    init(_ row: JSON) {
        hash = string(row["hash"]); originalSize = number(row["original_size"])
        objectID = number(row["object_id"]); chunks = Int(number(row["chunks"]))
        deleted = number(row["deleted"]) != 0; syncPaused = number(row["sync_paused"]) != 0
    }
}

final class Database {
    private var handle: OpaquePointer?
    private let queryObserver: ((String) -> Void)?
    let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL, queryObserver: ((String) -> Void)? = nil, recover: ((Database) throws -> Void)? = nil) throws {
        self.queryObserver = queryObserver
        try Paths.privateDirectory(directory)
        url = directory.appendingPathComponent("index.db")
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw TASError("无法打开文件索引") }
        do {
            sqlite3_busy_timeout(handle, 5000)
            // Persistent triggers reference this connection-local capability. Old clients
            // cannot prepare writes, even when they disable foreign keys.
            guard sqlite3_create_function_v2(handle, "tas_history_writer", 0, SQLITE_UTF8, nil, { context, _, _ in
                sqlite3_result_int(context, 1)
            }, nil, nil, nil) == SQLITE_OK else { throw error }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try script("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
            // Reconcile before schema migration/adoption can perform any writes.
            try recover?(self)
            guard let schema = Self.schemaURL else { throw TASError("缺少索引结构资源") }
            try script(String(contentsOf: schema, encoding: .utf8))
            try migrate()
            try versionSchema()
            for table in ["files", "pending_uploads"] {
                if !(try rows("PRAGMA table_info(\(table))")).contains(where: { string($0["name"]) == "key_id" }) {
                    try script("ALTER TABLE \(table) ADD COLUMN key_id TEXT")
                }
            }
            try script("CREATE TABLE IF NOT EXISTS manifest_journal(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL)")
            // Separate from mutation recovery: committed uploads must survive cancellation
            // even when there is no pending upload or prepared mutation left to resume.
            try script("CREATE TABLE IF NOT EXISTS manifest_dirty(id INTEGER PRIMARY KEY CHECK(id=1))")
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    private static var schemaURL: URL? {
        // Resolve installed resources by path before asking Foundation for Bundle.main.
        // A CLI helper inside an .app is not itself the application's main executable.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let parent = executable.deletingLastPathComponent()
        let candidates = [parent.deletingLastPathComponent().appendingPathComponent("Resources"), parent]
        for directory in candidates {
            for name in ["TAS_TASCore.bundle", "TAS_TASCore.resources"] {
                let root = directory.appendingPathComponent(name)
                for path in ["schema.sql", "Contents/Resources/schema.sql"] {
                    let file = root.appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: file.path) { return file }
                }
            }
        }
        return Bundle.module.url(forResource: "schema", withExtension: "sql")
    }
    deinit { sqlite3_close(handle) }
    private var error: TASError { TASError("索引操作失败：\(String(cString: sqlite3_errmsg(handle)))") }
    func script(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error } }
    @discardableResult func run(_ sql: String, _ parameters: [Any?] = []) throws -> Int64 {
        let statement = try prepare(sql, parameters); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
        return sqlite3_last_insert_rowid(handle)
    }
    func rows(_ sql: String, _ parameters: [Any?] = []) throws -> [JSON] {
        let statement = try prepare(sql, parameters); defer { sqlite3_finalize(statement) }
        var results: [JSON] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return results }
            guard status == SQLITE_ROW else { throw error }
            var row: JSON = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, i))
                case SQLITE_BLOB: row[name] = Data(bytes: sqlite3_column_blob(statement, i), count: Int(sqlite3_column_bytes(statement, i)))
                default: row[name] = NSNull()
                }
            }
            results.append(row)
        }
    }
    private func prepare(_ sql: String, _ parameters: [Any?]) throws -> OpaquePointer {
        queryObserver?(sql)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error }
        do {
            for (offset, value) in parameters.enumerated() {
                let index = Int32(offset + 1); let code: Int32
                switch value {
                case let value as String: code = sqlite3_bind_text(statement, index, value, -1, transient)
                case let value as NSNumber: code = sqlite3_bind_int64(statement, index, value.int64Value)
                case nil, is NSNull: code = sqlite3_bind_null(statement, index)
                default: throw TASError("不支持的索引参数")
                }
                guard code == SQLITE_OK else { throw error }
            }
        } catch { sqlite3_finalize(statement); throw error }
        return statement
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try script("BEGIN IMMEDIATE")
        do { let result = try body(); try script("COMMIT"); return result }
        catch { try? script("ROLLBACK"); throw error }
    }
    func backup(to destination: URL) throws {
        try require(!FileManager.default.fileExists(atPath: destination.path), "备份目标已存在")
        let file = try Paths.privateFile(destination); try file.close()
        var target: OpaquePointer?
        guard sqlite3_open(destination.path, &target) == SQLITE_OK else { throw error }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", handle, "main") else { throw error }
        let status = sqlite3_backup_step(backup, -1); let finish = sqlite3_backup_finish(backup)
        try require(status == SQLITE_DONE && finish == SQLITE_OK, "索引备份失败")
    }
    private func migrate() throws {
        let additions = [("chunks", "bot_id", "TEXT"), ("pending_chunks", "bot_id", "TEXT"), ("pending_chunks", "size", "INTEGER NOT NULL DEFAULT 0"), ("pending_uploads", "stored_size", "INTEGER NOT NULL DEFAULT 0"), ("pending_uploads", "compressed", "INTEGER NOT NULL DEFAULT -1")]
        var changes: [String] = []
        for (table, column, definition) in additions {
            if !(try rows("PRAGMA table_info(\(table))")).contains(where: { string($0["name"]) == column }) { changes.append("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)") }
        }
        var rebuild: [(String, String)] = []
        for table in ["files", "pending_uploads"] {
            for index in try rows("PRAGMA index_list(\(table))") where number(index["unique"]) == 1 {
                let name = string(index["name"]).replacingOccurrences(of: "\"", with: "\"\"")
                let columns = try rows("PRAGMA index_info(\"\(name)\")")
                if columns.count == 1 && string(columns[0]["name"]) == "hash" {
                    let sql = string(try rows("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", [table]).first?["sql"])
                    let replacement = sql.replacingOccurrences(of: "hash TEXT NOT NULL UNIQUE", with: "hash TEXT NOT NULL", options: .caseInsensitive)
                    try require(replacement != sql, "旧索引的唯一约束需要手动迁移；原文件未修改")
                    rebuild.append((table, replacement))
                }
            }
        }
        guard !changes.isEmpty || !rebuild.isEmpty else { return }
        try backup(to: url.deletingLastPathComponent().appendingPathComponent("index-before-swift-\(UUID().uuidString).db"))
        try script("PRAGMA foreign_keys=OFF")
        defer { try? script("PRAGMA foreign_keys=ON") }
        try transaction {
            for (table, sql) in rebuild {
                let newSQL = sql.replacingOccurrences(of: "CREATE TABLE \(table)", with: "CREATE TABLE \(table)_migrated", options: .caseInsensitive)
                try require(newSQL != sql, "无法迁移旧索引")
                try script(newSQL)
                try script("INSERT INTO \(table)_migrated SELECT * FROM \(table); DROP TABLE \(table); ALTER TABLE \(table)_migrated RENAME TO \(table);")
            }
            for change in changes { try script(change) }
            try script("CREATE INDEX IF NOT EXISTS idx_files_filename ON files(filename); CREATE INDEX IF NOT EXISTS idx_files_hash ON files(hash);")
            try require(try rows("PRAGMA foreign_key_check").isEmpty, "索引包含失效的关联记录")
        }
    }
    func files(search: String = "", tag: String? = nil, includeDeleted: Bool = false) throws -> [StoredFile] {
        try adoptLegacyObjects()
        var sql = "SELECT o.*,l.id,l.filename,l.created_at,l.updated_at,l.deleted,l.sync_paused,v.object_id,v.number AS version_number,(SELECT COUNT(*) FROM file_versions WHERE file_id=l.id) AS version_count FROM logical_files l JOIN file_versions v ON v.id=l.current_version_id JOIN files o ON o.id=v.object_id WHERE instr(lower(l.filename),lower(?))>0"; var params: [Any?] = [search]
        if !includeDeleted { sql += " AND l.deleted=0" }
        if let tag { sql += " AND l.id IN (SELECT file_id FROM tags WHERE tag=?)"; params.append(tag) }
        return try rows(sql + " ORDER BY l.filename COLLATE NOCASE", params).map { row in
            StoredFile(row, tags: try rows("SELECT tag FROM tags WHERE file_id=? ORDER BY tag", [row["id"]]).map { string($0["tag"]) })
        }
    }
    func currentFileState(filename: String) throws -> CurrentFileState? {
        // The unique logical filename index makes each lookup independent of
        // library size. Always re-read after uploads; no stale per-run cache.
        try rows("SELECT l.deleted,l.sync_paused,v.object_id,o.hash,o.original_size,o.chunks FROM logical_files l JOIN file_versions v ON v.id=l.current_version_id JOIN files o ON o.id=v.object_id WHERE l.filename=?", [filename]).first.map(CurrentFileState.init)
    }
    func manifest(includeShares: Bool = false) throws -> JSON {
        var result: JSON = ["schemaVersion": 3, "logicalFiles": try rows("SELECT * FROM logical_files ORDER BY id"), "versions": try rows("SELECT * FROM file_versions ORDER BY id"), "createdAt": timestamp(), "files": try rows("SELECT * FROM files ORDER BY id"), "chunks": try rows("SELECT * FROM chunks ORDER BY file_id,chunk_index"), "tags": try rows("SELECT * FROM tags ORDER BY id")]
        if includeShares { result["shares"] = try rows("SELECT * FROM shares") }
        return result
    }
}
