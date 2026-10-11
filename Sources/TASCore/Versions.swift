import Foundation

public struct FileVersion: Identifiable, Codable, Hashable, Sendable {
    public let id: Int64
    public let fileID: Int64
    public let number: Int
    public let hash: String
    public let originalSize: Int64
    public let storedSize: Int64
    public let createdAt: String
    public let source: String
    public let message: String?
    public let restoredFromVersionID: Int64?
    public let isCurrent: Bool
    init(_ row: JSON) {
        id = TASCore.number(row["id"]); fileID = TASCore.number(row["file_id"]); number = Int(TASCore.number(row["number"]))
        hash = string(row["hash"]); originalSize = TASCore.number(row["original_size"]); storedSize = TASCore.number(row["stored_size"])
        createdAt = string(row["created_at"]); source = string(row["source"]); message = row["message"] as? String
        restoredFromVersionID = (row["restored_from_version_id"] as? NSNumber)?.int64Value
        isCurrent = TASCore.number(row["current_version_id"]) == id
    }
}

/// Bytes count distinct encrypted content objects, excluding chunk headers.
/// storedBytes covers all retained objects; historyBytes excludes active current objects.
public struct VaultStatistics: Codable, Sendable {
    public let files: Int
    public let deletedFiles: Int
    public let versions: Int
    public let originalBytes: Int64
    public let storedBytes: Int64
    public let historyBytes: Int64
}

extension Database {
    func statistics() throws -> VaultStatistics {
        let all = try files(includeDeleted: true)
        let objects = try rows("SELECT * FROM files WHERE id IN (SELECT object_id FROM file_versions)")
        let current = Set(all.filter { !$0.deleted }.map(\.objectID))
        return VaultStatistics(files: all.filter { !$0.deleted }.count, deletedFiles: all.filter(\.deleted).count,
            versions: try rows("SELECT id FROM file_versions").count,
            originalBytes: try checkedByteTotal(all.filter { !$0.deleted }.map(\.originalSize)),
            storedBytes: try checkedByteTotal(objects.map { number($0["stored_size"]) }),
            historyBytes: try checkedByteTotal(objects.filter { !current.contains(number($0["id"])) }.map { number($0["stored_size"]) }))
    }
    func versionFile(_ id: Int64, number version: Int) throws -> StoredFile {
        guard let row = try rows("SELECT o.*,l.id,l.filename,v.object_id,v.number AS version_number FROM file_versions v JOIN files o ON o.id=v.object_id JOIN logical_files l ON l.id=v.file_id WHERE v.file_id=? AND v.number=?", [id, version]).first else { throw TASError("历史版本不存在") }
        return StoredFile(row)
    }
    func allVersionObjects() throws -> [StoredFile] {
        try rows("SELECT * FROM files WHERE id IN (SELECT object_id FROM file_versions) ORDER BY id").map { StoredFile($0) }
    }
    func versionSchema() throws {
        let needsMigration = try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='logical_files'").isEmpty
        if try needsMigration && !rows("SELECT id FROM files LIMIT 1").isEmpty {
            try backup(to: url.deletingLastPathComponent().appendingPathComponent("index-before-versions-\(UUID().uuidString).db"))
        }
        try transaction {
        for (column, definition) in [("message", "TEXT"), ("source", "TEXT NOT NULL DEFAULT 'upload'")] {
            if !(try rows("PRAGMA table_info(pending_uploads)")).contains(where: { string($0["name"]) == column }) {
                try script("ALTER TABLE pending_uploads ADD COLUMN \(column) \(definition)")
            }
        }
        try script("""
        CREATE TABLE IF NOT EXISTS logical_files (
          id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT NOT NULL UNIQUE,
          current_version_id INTEGER, deleted INTEGER NOT NULL DEFAULT 0, sync_paused INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL DEFAULT (datetime('now')), updated_at TEXT NOT NULL DEFAULT (datetime('now')));
        CREATE TABLE IF NOT EXISTS file_versions (
          id INTEGER PRIMARY KEY AUTOINCREMENT, file_id INTEGER NOT NULL REFERENCES logical_files(id) ON DELETE CASCADE,
          object_id INTEGER NOT NULL REFERENCES files(id), number INTEGER NOT NULL CHECK(number>0),
          created_at TEXT NOT NULL DEFAULT (datetime('now')), source TEXT NOT NULL DEFAULT 'migration', message TEXT,
          restored_from_version_id INTEGER REFERENCES file_versions(id), UNIQUE(file_id,number));
        """)
        try adoptLegacyObjects()
        // Tags and shares identify logical paths, never a particular content object.
        for table in ["tags", "shares"] {
            if try rows("PRAGMA foreign_key_list(\(table))").contains(where: { string($0["table"]) == "files" }) {
                let sql = string(try rows("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", [table]).first?["sql"])
                let migrated = sql.replacingOccurrences(of: "CREATE TABLE \(table)", with: "CREATE TABLE \(table)_logical", options: .caseInsensitive)
                    .replacingOccurrences(of: "REFERENCES files", with: "REFERENCES logical_files", options: .caseInsensitive)
                try script(migrated)
                try script("INSERT INTO \(table)_logical SELECT * FROM \(table); DROP TABLE \(table); ALTER TABLE \(table)_logical RENAME TO \(table);")
            }
        }
        try script("CREATE INDEX IF NOT EXISTS idx_tags_tag ON tags(tag); CREATE INDEX IF NOT EXISTS idx_shares_token ON shares(token);")
        for table in ["files", "chunks", "tags", "shares", "logical_files", "file_versions", "pending_uploads", "pending_chunks", "sync_state", "sync_folders"] {
            for action in ["INSERT", "UPDATE", "DELETE"] {
                try script("CREATE TRIGGER IF NOT EXISTS history_guard_\(table)_\(action) BEFORE \(action) ON \(table) BEGIN SELECT CASE WHEN tas_history_writer()!=1 THEN RAISE(ABORT,'history-aware client required') END; END;")
            }
        }
        }
    }
    func adoptLegacyObjects() throws {
        for object in try rows("SELECT * FROM files WHERE id NOT IN (SELECT object_id FROM file_versions) ORDER BY id") {
            let id = number(object["id"]); let original = string(object["filename"])
            var name = original; var suffix = 0
            while !(try rows("SELECT id FROM logical_files WHERE filename=?", [name])).isEmpty {
                repeat {
                    suffix += 1; name = original + " (imported-\(id)-\(suffix))"
                } while !(try rows("SELECT id FROM files WHERE filename=?", [name])).isEmpty
            }
            var logicalID = id
            if !(try rows("SELECT id FROM logical_files WHERE id=?", [id])).isEmpty {
                logicalID = number(try rows("SELECT MAX(n)+1 AS next FROM (SELECT COALESCE(MAX(id),0) AS n FROM files UNION ALL SELECT COALESCE(MAX(id),0) FROM logical_files)").first?["next"])
            }
            try run("INSERT INTO logical_files(id,filename,created_at,updated_at) VALUES(?,?,?,?)", [logicalID, name, object["created_at"], object["updated_at"]])
            let versionID = try appendVersion(logicalID, objectID: id, source: "migration")
            try run("UPDATE file_versions SET created_at=? WHERE id=?", [object["created_at"], versionID])
            try run("UPDATE logical_files SET updated_at=? WHERE id=?", [object["updated_at"], logicalID])
        }
    }
    @discardableResult func appendVersion(_ fileID: Int64, objectID: Int64, source: String, message: String? = nil, restoredFrom: Int64? = nil) throws -> Int64 {
        let next = number(try rows("SELECT COALESCE(MAX(number),0)+1 AS n FROM file_versions WHERE file_id=?", [fileID]).first?["n"])
        let id = try run("INSERT INTO file_versions(file_id,object_id,number,source,message,restored_from_version_id) VALUES(?,?,?,?,?,?)", [fileID, objectID, next, source, message, restoredFrom])
        try run("UPDATE logical_files SET current_version_id=?,updated_at=? WHERE id=?", [id, timestamp(), fileID])
        return id
    }
    func history(_ id: Int64) throws -> [FileVersion] {
        try rows("SELECT o.hash,o.original_size,o.stored_size,v.*,l.current_version_id FROM file_versions v JOIN files o ON o.id=v.object_id JOIN logical_files l ON l.id=v.file_id WHERE v.file_id=? ORDER BY v.number DESC", [id]).map(FileVersion.init)
    }
}
