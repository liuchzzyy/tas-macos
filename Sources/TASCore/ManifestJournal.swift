import Foundation

/// A durable outbox. `prepared` has no published pointer and can be abandoned.
/// Once the upload receipt is durable, recovery MUST roll forward before any use
/// of the vault. The previous remote index is retained until SQLite and config
/// have both been finalized. Unknown upload outcomes may leak an orphan, never
/// remove the last recoverable snapshot.
enum ManifestJournal {
    static func owners(_ config: Configuration) throws -> Data {
        try jsonData(config.bots.sorted { $0.id < $1.id }.map {
            ["id": $0.id, "endpoint": $0.endpoint, "chat": $0.chatID, "token": $0.token]
        })
    }
    static func store(_ record: JSON, db: Database, password: String) throws {
        let encrypted = try Crypto.encrypt(jsonData(record), password: password).base64EncodedString()
        try db.run("INSERT OR REPLACE INTO manifest_journal(id,payload) VALUES(1,?)", [encrypted])
    }
    static func read(_ db: Database, password: String) throws -> JSON? {
        guard !(try db.rows("SELECT name FROM sqlite_master WHERE type='table' AND name='manifest_journal'")).isEmpty,
              let row = try db.rows("SELECT payload FROM manifest_journal WHERE id=1").first else { return nil }
        guard let data = Data(base64Encoded: string(row["payload"])) else { throw TASError("索引发布日志损坏") }
        return try jsonObject(Crypto.decrypt(data, password: password))
    }
    static func recover(db: Database, config: Configuration, password: String, boundary: (String) throws -> Void = { _ in }) throws {
        guard let record = try read(db, password: password) else { return }
        try require(string(record["owners"]) == (try owners(config)).base64EncodedString(), "索引发布待恢复，机器人配置已改变；拒绝写入")
        guard let pointer = record["pointer"] as? JSON else {
            // No receipt was made durable: SQLite/config were never changed.
            try db.run("DELETE FROM manifest_journal WHERE id=1")
            return
        }
        guard let snapshot = record["snapshot"] as? JSON else { throw TASError("索引发布日志缺少快照") }
        if string(record["phase"]) != "committed" {
            let tables = try Database.validatedManifest(snapshot)
            try db.transaction {
                try db.replaceManifestTables(tables, clearSyncState: false)
                var committed = record; committed["phase"] = "committed"
                try store(committed, db: db, password: password)
            }
        }
        try boundary("databaseCommitted")
        config.raw["remoteManifest"] = pointer
        try config.save()
        try boundary("pointerFinalized")
        try db.run("DELETE FROM manifest_journal WHERE id=1")
        try boundary("journalCleared")
        // No network in constructors. A crash can leave old indexes/chunks behind;
        // this is conservative garbage, not lost data or an inconsistent pointer.
    }
}
