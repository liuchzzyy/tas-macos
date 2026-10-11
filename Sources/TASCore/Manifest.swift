import Foundation

extension Database {
    /// Validate the complete graph before replacing any local state.
    static func validatedManifest(_ manifest: JSON) throws -> [(String, [JSON])] {
        let schema = number(manifest["schemaVersion"])
        // Do not coerce malformed strings/fractions to zero or truncate them.
        func integer(_ value: Any?) throws {
            guard let value = value as? NSNumber,
                  Int64(value.stringValue) != nil else { throw TASError("恢复索引需要整数值") }
        }
        try integer(manifest["schemaVersion"])
        let numericFields = [
            "files": ["id", "original_size", "stored_size", "chunks", "compressed"],
            "chunks": ["id", "file_id", "chunk_index", "size"],
            "logicalFiles": ["id", "current_version_id", "deleted", "sync_paused"],
            "versions": ["id", "file_id", "object_id", "number"],
            "tags": ["id", "file_id"], "shares": ["id", "file_id", "max_downloads", "download_count"]
        ]
        for (table, fields) in numericFields {
            if let value = manifest[table] {
                guard let records = value as? [JSON] else { throw TASError("恢复索引列表格式错误") }
                for record in records {
                    for field in fields { try integer(record[field]) }
                    if let restored = record["restored_from_version_id"], !(restored is NSNull) { try integer(restored) }
                }
            }
        }
        try require(schema == 1 || schema == 2, "不支持的恢复索引版本")
        guard let objects = manifest["files"] as? [JSON], let chunks = manifest["chunks"] as? [JSON] else { throw TASError("恢复索引格式错误") }
        func identifiers(_ records: [JSON]) throws -> Set<Int64> {
            let ids = Set(records.map { number($0["id"]) })
            try require(ids.count == records.count && ids.allSatisfy { $0 > 0 }, "恢复索引编号无效或重复")
            return ids
        }
        let objectIDs = try identifiers(objects)
        _ = try checkedByteTotal(objects.map { number($0["original_size"]) })
        _ = try checkedByteTotal(objects.map { number($0["stored_size"]) })
        _ = try identifiers(chunks)
        let groupedChunks = Dictionary(grouping: chunks) { number($0["file_id"]) }
        for object in objects {
            let filename = string(object["filename"])
            try require(try Paths.logical(filename) == filename, "恢复索引路径无效")
            let hash = string(object["hash"])
            try require(hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) }, "恢复索引哈希无效")
            let stored = number(object["stored_size"])
            try require(number(object["original_size"]) >= 0 && stored >= 0 && [0,1].contains(number(object["compressed"])), "恢复索引大小或压缩标记无效")
            let owned = (groupedChunks[number(object["id"])] ?? []).sorted { number($0["chunk_index"]) < number($1["chunk_index"]) }
            try require(owned.count == Int(number(object["chunks"])) && !owned.isEmpty && owned.count <= 65535, "恢复索引分块不完整")
            var bytes: Int64 = 0
            for (index, chunk) in owned.enumerated() {
                let size = number(chunk["size"])
                try require(number(chunk["chunk_index"]) == Int64(index) && !string(chunk["message_id"]).isEmpty && !string(chunk["file_telegram_id"]).isEmpty && size >= Int64(Crypto.headerSize), "恢复索引分块信息无效")
                let (sum, overflow) = bytes.addingReportingOverflow(size - Int64(Crypto.headerSize))
                try require(!overflow, "恢复索引大小溢出"); bytes = sum
            }
            try require(bytes == stored, "恢复索引分块总大小不匹配")
        }
        try require(chunks.allSatisfy { objectIDs.contains(number($0["file_id"])) }, "恢复索引包含无主分块")
        let logical: [JSON], versions: [JSON]
        if schema == 2 {
            guard let l = manifest["logicalFiles"] as? [JSON], let v = manifest["versions"] as? [JSON] else { throw TASError("恢复索引缺少历史") }
            logical = l; versions = v
        } else {
            var names = Set(objects.map { string($0["filename"]) })
            var used = Set<String>(); var l: [JSON] = []; var v: [JSON] = []
            for object in objects.sorted(by: { number($0["id"]) < number($1["id"]) }) {
                let id = number(object["id"]); let original = string(object["filename"])
                var name = original; var suffix = 0
                if used.contains(name) {
                    repeat { suffix += 1; name = original + " (imported-\(id)-\(suffix))" } while names.contains(name)
                }
                names.insert(name); used.insert(name)
                l.append(["id": id, "filename": name, "current_version_id": id, "deleted": 0, "sync_paused": 0, "created_at": object["created_at"] ?? timestamp(), "updated_at": object["updated_at"] ?? timestamp()])
                v.append(["id": id, "file_id": id, "object_id": id, "number": 1, "source": "migration", "created_at": object["created_at"] ?? timestamp()])
            }
            logical = l; versions = v
        }
        let logicalIDs = try identifiers(logical), versionIDs = try identifiers(versions)
        let byID = Dictionary(uniqueKeysWithValues: versions.map { (number($0["id"]), $0) })
        let byFile = Dictionary(grouping: versions) { number($0["file_id"]) }
        var names = Set<String>()
        for file in logical {
            let name = string(file["filename"])
            try require(try Paths.logical(name) == name && names.insert(name).inserted, "恢复索引逻辑路径无效或重复")
            try require([0,1].contains(number(file["deleted"])) && [0,1].contains(number(file["sync_paused"])), "恢复索引状态无效")
            let owned = (byFile[number(file["id"])] ?? []).sorted { number($0["number"]) < number($1["number"]) }
            try require(!owned.isEmpty && owned.enumerated().allSatisfy { number($0.element["number"]) == Int64($0.offset + 1) }, "恢复索引历史序列无效")
            try require(number(owned.last?["id"]) == number(file["current_version_id"]), "恢复索引当前版本无效")
        }
        for version in versions {
            try require(logicalIDs.contains(number(version["file_id"])) && objectIDs.contains(number(version["object_id"])), "恢复索引版本引用无效")
            try require(["upload", "sync", "restore", "migration"].contains(string(version["source"])), "恢复索引版本来源无效")
            if let restored = version["restored_from_version_id"], !(restored is NSNull) {
                guard versionIDs.contains(number(restored)), let origin = byID[number(restored)] else { throw TASError("恢复来源版本不存在") }
                try require(number(origin["file_id"]) == number(version["file_id"]) && number(origin["number"]) < number(version["number"]) && number(origin["object_id"]) == number(version["object_id"]), "恢复来源版本不匹配")
            } else { try require(string(version["source"]) != "restore", "恢复版本缺少来源") }
        }
        try require(Set(versions.map { number($0["object_id"]) }) == objectIDs, "恢复索引存在未引用内容")
        let tags = manifest["tags"] as? [JSON] ?? [], shares = manifest["shares"] as? [JSON] ?? []
        for records in [tags, shares] {
            _ = try identifiers(records)
            try require(records.allSatisfy { logicalIDs.contains(number($0["file_id"])) }, "恢复索引标签或分享引用无效")
        }
        let byObject = Dictionary(uniqueKeysWithValues: objects.map { (number($0["id"]), $0) })
        _ = try checkedByteTotal(logical.map { file in
            let objectID = number(byID[number(file["current_version_id"])]?["object_id"])
            return number(byObject[objectID]?["original_size"])
        })
        return [("files", objects), ("chunks", chunks), ("logical_files", logical), ("file_versions", versions), ("tags", tags), ("shares", shares)]
    }
    func importManifest(_ manifest: JSON) throws {
        try require(try rows("SELECT id FROM pending_uploads").isEmpty, "存在待上传任务，不能重建索引")
        let tables = try Self.validatedManifest(manifest)
        try transaction {
            try replaceManifestTables(tables, clearSyncState: true)
        }
    }
    func replaceManifestTables(_ tables: [(String, [JSON])], clearSyncState: Bool) throws {
            try script("PRAGMA defer_foreign_keys=ON; DELETE FROM shares; DELETE FROM tags; DELETE FROM file_versions; DELETE FROM logical_files; DELETE FROM chunks; DELETE FROM files;")
            if clearSyncState { try script("DELETE FROM sync_state") }
            for (table, records) in tables {
                let allowed = Set(try rows("PRAGMA table_info(\(table))").map { string($0["name"]) })
                for record in records {
                    let columns = record.keys.filter { allowed.contains($0) }.sorted()
                    try run("INSERT INTO \(table) (\(columns.joined(separator: ","))) VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ",")))", columns.map { record[$0] })
                }
            }
            try require(try rows("PRAGMA foreign_key_check").isEmpty, "恢复索引关联不完整")
    }
}
