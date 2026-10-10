import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct UploadedChunk { let messageID: String; let fileID: String }
protocol TelegramTransport {
    func check(_ bot: Bot) async throws -> String
    func send(_ file: URL, caption: String, bot: Bot) async throws -> UploadedChunk
    func download(_ fileID: String, to destination: URL, bot: Bot) async throws
    func metadata(_ fileID: String, bot: Bot) async throws -> JSON
    func delete(_ messageID: String, bot: Bot) async throws
}
final class Telegram: TelegramTransport {
    private let session: URLSession
    private var nextSend: [String: Date] = [:]
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 3600
        config.httpCookieStorage = nil; config.urlCache = nil
        self.session = session ?? URLSession(configuration: config)
    }
    private func address(_ bot: Bot, method: String) throws -> URL {
        guard let url = URL(string: "\(bot.endpoint)/bot\(bot.token)/\(method)") else { throw TASError("Bot API 地址无效") }; return url
    }
    private func request(_ method: String, bot: Bot, parameters: JSON = [:], body: URL? = nil, contentType: String? = nil) async throws -> JSON {
        var request = URLRequest(url: try address(bot, method: method)); request.httpMethod = "POST"
        request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        if body == nil { request.httpBody = try jsonData(parameters) }
        for attempt in 0..<5 {
            try Task.checkCancellation()
            do {
                let pair: (Data, URLResponse)
                if let body { pair = try await session.upload(for: request, fromFile: body) }
                else { pair = try await session.data(for: request) }
                let status = (pair.1 as? HTTPURLResponse)?.statusCode ?? 0
                let response = (try? jsonObject(pair.0)) ?? [:]
                if status == 429 || number(response["error_code"]) == 429 || status >= 500 {
                    if attempt == 4 { throw TASError("Telegram 暂时不可用，请稍后重试") }
                    let delay = min(300, max(Int64(1 << attempt), number((response["parameters"] as? JSON)?["retry_after"])))
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000); continue
                }
                guard status == 200 && response["ok"] as? Bool == true else {
                    let description = string(response["description"]).replacingOccurrences(of: bot.token, with: "[token]")
                    throw TASError("Telegram \(status)：\(description.isEmpty ? "请求失败" : description)")
                }
                return response["result"] as? JSON ?? [:]
            } catch let error as URLError {
                if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
                if attempt == 4 { throw TASError("Telegram 网络连接失败（\(error.code.rawValue)）") }
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
            }
        }
        throw TASError("Telegram 请求失败")
    }
    func check(_ bot: Bot) async throws -> String {
        let user = try await request("getMe", bot: bot)
        _ = try await request("getChat", bot: bot, parameters: ["chat_id": bot.chatID])
        return string(user["username"])
    }
    func send(_ file: URL, caption: String, bot: Bot) async throws -> UploadedChunk {
        if let next = nextSend[bot.id], next > Date() { try await Task.sleep(nanoseconds: UInt64(next.timeIntervalSinceNow * 1_000_000_000)) }
        nextSend[bot.id] = Date().addingTimeInterval(1)
        let boundary = "tas-\(UUID().uuidString)"
        let body = file.deletingLastPathComponent().appendingPathComponent(".multipart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: body) }
        let output = try Paths.privateFile(body); defer { try? output.close() }
        for (key, value) in [("chat_id", bot.chatID), ("caption", caption)] {
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"document\"; filename=\"tas.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: data) }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8)); try output.close()
        let result = try await request("sendDocument", bot: bot, body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        let message = string(result["message_id"]), fileID = string((result["document"] as? JSON)?["file_id"])
        try require(!message.isEmpty && !fileID.isEmpty, "Telegram 返回了不完整的分块信息")
        return UploadedChunk(messageID: message, fileID: fileID)
    }
    func metadata(_ fileID: String, bot: Bot) async throws -> JSON { try await request("getFile", bot: bot, parameters: ["file_id": fileID]) }
    func download(_ fileID: String, to destination: URL, bot: Bot) async throws {
        let info = try await metadata(fileID, bot: bot); let path = string(info["file_path"])
        try require(!path.isEmpty, "Telegram 没有返回文件路径")
        if path.hasPrefix("/") && bot.raw["customApiUrl"] != nil {
            let source = URL(fileURLWithPath: path)
            try require(FileManager.default.fileExists(atPath: source.path), "本地 Bot API 返回的文件不在本机可访问的路径中")
            try copyPrivate(source, destination); return
        }
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "\(bot.endpoint)/file/bot\(bot.token)/\(escaped)") else { throw TASError("Telegram 文件地址无效") }
        do {
            let (temporary, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try require((response as? HTTPURLResponse)?.statusCode == 200, "Telegram 文件下载失败")
            try copyPrivate(temporary, destination)
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw TASError("Telegram 下载连接失败（\(error.code.rawValue)）")
        }
    }
    func delete(_ messageID: String, bot: Bot) async throws { _ = try await request("deleteMessage", bot: bot, parameters: ["chat_id": bot.chatID, "message_id": messageID]) }
}
func copyPrivate(_ source: URL, _ destination: URL) throws {
    let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
    let output = try Paths.privateFile(destination); defer { try? output.close() }
    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: data) }
    try output.synchronize()
}
