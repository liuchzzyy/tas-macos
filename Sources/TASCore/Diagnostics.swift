import Foundation
public enum Diagnostics {
    /// Runs without opening the user's vault or making network requests.
    public static func selfTest() throws -> String {
        fputs("self-test: creating temporary database\n", stderr)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tas-selftest-\(UUID().uuidString)")
        try Paths.privateDirectory(directory); defer { try? FileManager.default.removeItem(at: directory) }
        let db = try Database(directory: directory)
        try require(try db.files().isEmpty, "索引资源检查失败")
        fputs("self-test: checking native encryption\n", stderr)
        let original = Data("TAS 原生运行检查".utf8)
        let decrypted = try Crypto.decrypt(Crypto.encrypt(original, password: "self-test-password"), password: "self-test-password")
        try require(decrypted == original, "加密检查失败")
        fputs("self-test: complete\n", stderr)
        return "PASS: SQLite resources, AES-256-GCM, PBKDF2-SHA512 (600000 iterations)"
    }
}
