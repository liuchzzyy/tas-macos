import Foundation
import CryptoSwift

public struct BotInfo: Identifiable, Codable {
    public let id: String
    public let username: String
    public let chatID: String
    public let enabled: Bool
    public let endpoint: String?
}
struct Bot {
    var raw: JSON
    let token: String
    var id: String { string(raw["id"]) }
    var chatID: String { string(raw["chatId"]) }
    var enabled: Bool { raw["enabled"] as? Bool != false }
    var endpoint: String { (raw["customApiUrl"] as? String ?? "https://api.telegram.org").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var info: BotInfo { BotInfo(id: id, username: string(raw["username"]), chatID: chatID, enabled: enabled, endpoint: raw["customApiUrl"] as? String) }
}
final class Configuration {
    let url: URL
    var raw: JSON
    var bots: [Bot]
    private(set) var encryptionPassword: String
    private(set) var generationID: String
    private(set) var generations: [String: String]
    init(directory: URL, password: String) throws {
        url = directory.appendingPathComponent("config.json")
        raw = try jsonObject(Data(contentsOf: url))
        try require(try Crypto.verifyPassword(password, hash: string(raw["passwordHash"])), "密码不正确")
        try require(number(raw["configVersion"]) == 5, "不支持旧版文件库配置")
        guard let wrapped = raw["wrappedKeyring"] as? String, let data = Data(base64Encoded: wrapped) else { throw TASError("密钥环缺失") }
        let keyring = try jsonObject(Crypto.decrypt(data, password: password))
        guard let secret = keyring["manifestKey"] as? String, Self.validSecret(secret),
              let current = keyring["current"] as? String,
              let keys = keyring["keys"] as? [String: String], !keys.isEmpty,
              keys[current] != nil,
              keys.allSatisfy({ UUID(uuidString: $0.key) != nil && Self.validSecret($0.value) }) else { throw TASError("密钥环无效") }
        encryptionPassword = secret; generationID = current; generations = keys
        var entries = raw["bots"] as? [JSON] ?? [raw.merging(["id": "primary", "enabled": true]) { _, new in new }]
        for index in entries.indices where string(entries[index]["id"]).isEmpty { entries[index]["id"] = index == 0 ? "primary" : "bot-\(index + 1)" }
        let cryptoPassword = encryptionPassword
        bots = try entries.map { entry in
            let token: String
            if let plaintext = entry["botToken"] as? String { token = plaintext }
            else if let value = entry["encryptedBotToken"] as? String, let encrypted = Data(base64Encoded: value), let decrypted = String(data: try Crypto.decrypt(encrypted, password: cryptoPassword), encoding: .utf8) { token = decrypted }
            else { throw TASError("无法解密机器人配置") }
            try Self.validate(id: string(entry["id"]), token: token, chatID: string(entry["chatId"]), endpoint: entry["customApiUrl"] as? String)
            return Bot(raw: entry, token: token)
        }
        try require(!bots.isEmpty && bots.contains(where: { $0.enabled }) && Set(bots.map(\.id)).count == bots.count, "机器人配置无效")
    }
    static func validate(id: String, token: String, chatID: String, endpoint: String?) throws {
        try require(id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$", options: .regularExpression) != nil, "机器人编号只能包含字母、数字、横线和下划线，最多 32 个字符")
        try require(token.range(of: "^[0-9]+:[A-Za-z0-9_-]+$", options: .regularExpression) != nil && !chatID.isEmpty, "请填写有效的 Bot Token 和 Chat ID")
        if let endpoint, !endpoint.isEmpty {
            guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw TASError("Bot API 地址必须是有效的 HTTP(S) 地址") }
        }
    }
    static func create(directory: URL, password: String, token: String, chatID: String, endpoint: String? = nil) throws {
        try require(PasswordPolicy.isValid(password), "加密密码须至少 12 位，并包含大写、小写字母、数字和符号")
        try validate(id: "primary", token: token, chatID: chatID, endpoint: endpoint)
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.db").path), "此目录已有配置或索引，请解锁现有文件库")
        var bot: JSON = ["id": "primary", "chatId": chatID, "enabled": true, "createdAt": timestamp()]
        if let endpoint, !endpoint.isEmpty { bot["customApiUrl"] = endpoint }
        let generation = UUID().uuidString
        let manifestKey = Self.randomSecret()
        bot["encryptedBotToken"] = try Crypto.encrypt(Data(token.utf8), password: manifestKey).base64EncodedString()
        let ring: JSON = ["manifestKey": manifestKey, "current": generation, "keys": [generation: Self.randomSecret()]]
        let config: JSON = ["configVersion": 5, "passwordHash": try Crypto.passwordHash(password), "wrappedKeyring": try Crypto.encrypt(jsonData(ring), password: password).base64EncodedString(), "bots": [bot], "createdAt": timestamp()]
        try Paths.atomicWrite(jsonData(config), to: directory.appendingPathComponent("config.json"))
    }
    func save() throws { try Paths.atomicWrite(jsonData(raw), to: url) }
    private static func randomSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }).base64EncodedString()
    }
    private static func validSecret(_ secret: String) -> Bool {
        guard let bytes = Data(base64Encoded: secret), bytes.count == 32 else { return false }
        return bytes.base64EncodedString() == secret
    }
    func objectKey(_ id: String) throws -> String {
        guard let key = generations[id] else { throw TASError("文件加密密钥不存在：\(id)") }
        return key
    }
    /// Commit verifier and encrypted keyring together; remote ciphertext and
    /// recovery pointer stay usable because the manifest key never rotates.
    func changePassword(old: String, new: String, confirmation: String) throws {
        try require(try Crypto.verifyPassword(old, hash: string(raw["passwordHash"])), "密码不正确")
        try require(PasswordPolicy.isValid(new), "加密密码须至少 12 位，并包含大写、小写字母、数字和符号")
        try require(new == confirmation, "两次输入的密码不一致")
        try require(new != old, "新密码不能与旧密码相同")
        var candidate = raw
        let nextID = UUID().uuidString
        var nextKeys = generations; nextKeys[nextID] = Self.randomSecret()
        let ring: JSON = ["manifestKey": encryptionPassword, "current": nextID, "keys": nextKeys]
        candidate["passwordHash"] = try Crypto.passwordHash(new)
        candidate["wrappedKeyring"] = try Crypto.encrypt(jsonData(ring), password: new).base64EncodedString()
        try Paths.atomicWrite(jsonData(candidate), to: url)
        raw = candidate; generations = nextKeys; generationID = nextID
    }
    /// Commit the proposed bot list only after the new config is durable: the
    /// caller's in-memory list and `raw` stay untouched when the write fails.
    func saveBots(password: String, replacing replacement: [Bot]? = nil) throws {
        let botsToSave = replacement ?? bots
        var candidate = raw
        candidate["configVersion"] = 5
        candidate["bots"] = try botsToSave.map { bot -> JSON in
            var entry = bot.raw; entry.removeValue(forKey: "botToken")
            if entry["encryptedBotToken"] == nil { entry["encryptedBotToken"] = try Crypto.encrypt(Data(bot.token.utf8), password: password).base64EncodedString() }
            return entry
        }
        for key in ["botToken", "encryptedBotToken", "chatId", "username", "customApiUrl"] { candidate.removeValue(forKey: key) }
        try Paths.atomicWrite(jsonData(candidate), to: url)
        raw = candidate
        bots = botsToSave
    }
    func owner(_ id: String?) throws -> Bot {
        if let id, !id.isEmpty, let bot = bots.first(where: { $0.id == id }) { return bot }
        if id == nil || id!.isEmpty {
            if let primary = bots.first(where: { $0.id == "primary" }) { return primary }
            if bots.count == 1 { return bots[0] }
        }
        throw TASError("分块所属机器人未配置：\(id ?? "primary")")
    }
    func select(_ routingKey: String, index: Int) throws -> Bot {
        let enabled = bots.filter(\.enabled)
        try require(!enabled.isEmpty, "至少需要一个启用的机器人")
        let digest = Array(routingKey.utf8).sha256()
        let offset = digest.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return enabled[(Int(offset % UInt64(enabled.count)) + index) % enabled.count]
    }
}
