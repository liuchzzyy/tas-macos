import Foundation
import TASCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct Arguments {
    var values: [String]
    mutating func flag(_ key: String) -> Bool { if let i = values.firstIndex(of: key) { values.remove(at: i); return true }; return false }
    mutating func option(_ key: String) throws -> String? {
        guard let i = values.firstIndex(of: key) else { return nil }
        guard i + 1 < values.count && !values[i + 1].hasPrefix("--") else { throw TASError("\(key) 缺少参数") }
        values.remove(at: i); return values.remove(at: i)
    }
    mutating func pop(_ hint: String) throws -> String { guard !values.isEmpty else { throw TASError(hint) }; return values.removeFirst() }
    func finish() throws { if !values.isEmpty { throw TASError("无法识别参数：\(values.joined(separator: " "))") } }
}
@main struct CLI {
    static let help = """
    TAS 1.0 — 原生 Swift Telegram 文件库
    用法：tas <命令> [选项]

      init                       创建文件库，交互输入 Token、Chat ID 和密码
      push <文件...>             上传（--name 路径，--replace 替换同名文件）
      pull <ID或完整路径>         下载（--output 目标文件）
      list | search <关键词>     列出文件（--tag 标签，--json）
      delete <ID或完整路径>       删除索引（--hard 同时删除 Telegram 消息）
      tag add|remove <文件> <标签>
      resume                     继续上传（--clear ID 清除任务）
      status                     查看文件、容量和待上传任务（--json）
      bot list|add|enable|disable|remove|endpoint
      index backup|rebuild       备份／恢复加密索引
      verify                     检查远端分块（--deep 下载解密并校验）
      sync add <目录> | remove <ID> | status | start [--watch]
      sync pull <目录>           按逻辑路径恢复全部文件
      doctor                     检查机器人连接和 SQLite 完整性

    通用：--data-dir 目录，--password-file 文件，--help，--version
    默认使用 ~/.tas；支持 TAS_DATA_DIR、TAS_PASSWORD、TAS_BOT_TOKEN、TAS_CHAT_ID。
    密码文件必须为单行且权限为 600。退出会释放文件库锁。
    """
    static func main() async {
        do { try await run() }
        catch is CancellationError { fputs("任务已取消；上传可通过 tas resume 继续。\n", stderr); exit(130) }
        catch { fputs("错误：\(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func password(_ path: String?) throws -> String {
        if let path {
            let url = URL(fileURLWithPath: path); let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 16384, ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw TASError("密码文件必须为普通文件、小于 16KiB，且权限不开放给其他用户") }
            var value = try String(contentsOf: url, encoding: .utf8)
            if value.hasSuffix("\n") { value.removeLast(); if value.hasSuffix("\r") { value.removeLast() } }
            guard !value.isEmpty && !value.contains("\n") && !value.contains("\r") else { throw TASError("密码文件必须恰好包含一行非空密码") }; return value
        }
        if let value = ProcessInfo.processInfo.environment["TAS_PASSWORD"], !value.isEmpty { return value }
        guard isatty(STDIN_FILENO) != 0, let value = getpass("加密密码：") else { throw TASError("请通过安全的密码文件或交互终端提供密码") }
        return String(cString: value)
    }
    static func input(_ prompt: String, secret: Bool = false) throws -> String {
        if secret { guard let value = getpass(prompt) else { throw TASError("无法读取输入") }; return String(cString: value) }
        print(prompt, terminator: ""); guard let value = readLine(), !value.isEmpty else { throw TASError("输入不能为空") }; return value
    }
    static func emit<T: Encodable>(_ value: T) throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; print(String(decoding: try encoder.encode(value), as: UTF8.self)) }
    static func result(_ value: OperationResult) { print(value.message); if let warning = value.warning { fputs("提示：\(warning)\n", stderr) } }
    static func identify(_ value: String, vault: Vault) async throws -> Int64 {
        if let id = Int64(value) { return id }
        let matches = try await vault.files(search: value).filter { $0.filename == value }
        guard matches.count == 1 else { throw TASError("请使用文件 ID 或完整逻辑路径") }; return matches[0].id
    }
    static func run() async throws {
        var args = Arguments(values: Array(CommandLine.arguments.dropFirst()))
        if args.flag("--self-test") { print(try Diagnostics.selfTest()); return }
        if args.flag("--help") || args.values.isEmpty { print(help); return }
        if args.flag("--version") { print("tas 1.0.1 (Swift)"); return }
        let directory = try args.option("--data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Paths.dataDirectory
        let passwordFile = try args.option("--password-file"); let json = args.flag("--json")
        let command = try args.pop("缺少命令")
        let password = try password(passwordFile)
        if command == "init" {
            let token = try ProcessInfo.processInfo.environment["TAS_BOT_TOKEN"] ?? input("Bot Token：", secret: true)
            let chat = try ProcessInfo.processInfo.environment["TAS_CHAT_ID"] ?? input("Chat ID：")
            let endpoint = try args.option("--endpoint"); try args.finish()
            try await Vault.create(directory: directory, password: password, token: token, chatID: chat, endpoint: endpoint)
            print("文件库已创建：\(directory.path)"); return
        }
        let vault = try Vault(directory: directory, password: password)
        let progress: ProgressHandler = { event in fputs("\(event.message)\n", stderr) }
        switch command {
        case "list", "ls", "search":
            let tag = try args.option("--tag"); let search = command == "search" ? try args.pop("缺少搜索词") : ""; try args.finish()
            let files = try await vault.files(search: search, tag: tag)
            if json { try emit(files) } else { for file in files { print("\(file.id)\t\(ByteCountFormatter.string(fromByteCount: file.originalSize, countStyle: .file))\t\(file.filename)\t\(file.tags.joined(separator: ","))") } }
        case "push":
            let name = try args.option("--name"); let replace = args.flag("--replace")
            guard !args.values.isEmpty && (name == nil || args.values.count == 1) else { throw TASError("请提供文件；--name 仅用于单个文件") }
            for path in args.values { result(try await vault.upload(URL(fileURLWithPath: path), name: name, replace: replace, progress: progress)) }
        case "pull":
            let output = try args.option("--output"); let id = try await identify(args.pop("缺少文件 ID"), vault: vault); try args.finish()
            guard let file = try await vault.files().first(where: { $0.id == id }) else { throw TASError("文件不存在") }
            let target = URL(fileURLWithPath: output ?? URL(fileURLWithPath: file.filename).lastPathComponent)
            try await vault.download(id, to: target, progress: progress); print(target.path)
        case "delete", "rm":
            let hard = args.flag("--hard"); let id = try await identify(args.pop("缺少文件 ID"), vault: vault); try args.finish(); result(try await vault.delete(id, hard: hard))
        case "tag":
            let action = try args.pop("缺少 add/remove"); let id = try await identify(args.pop("缺少文件 ID"), vault: vault); let value = try args.pop("缺少标签"); try args.finish()
            guard ["add", "remove"].contains(action) else { throw TASError("请使用 tag add/remove") }; result(try await vault.tag(id, value: value, remove: action == "remove"))
        case "resume":
            if let clear = try args.option("--clear"), let id = Int64(clear) { try args.finish(); result(try await vault.clearPending(id)) }
            else { try args.finish(); result(try await vault.resume(progress: progress)) }
        case "status":
            try args.finish(); let files = try await vault.files(), pending = try await vault.pending()
            struct Status: Encodable { let files: Int; let originalBytes: Int64; let storedBytes: Int64; let pending: [PendingUpload]; let manifestDate: String? }
            let status = await Status(files: files.count, originalBytes: files.reduce(0) { $0 + $1.originalSize }, storedBytes: files.reduce(0) { $0 + $1.storedSize }, pending: pending, manifestDate: vault.manifestDate())
            if json { try emit(status) } else { print("\(status.files) 个文件 · 原始 \(status.originalBytes) 字节 · 已存储 \(status.storedBytes) 字节\n待上传：\(pending.count)\n索引备份：\(status.manifestDate ?? "尚未备份")") }
        case "index":
            let action = try args.pop("缺少 backup/rebuild"); try args.finish()
            switch action { case "backup": result(try await vault.backupIndex()); case "rebuild": result(try await vault.rebuildIndex()); default: throw TASError("请使用 index backup/rebuild") }
        case "verify": let deep = args.flag("--deep"); try args.finish(); result(try await vault.verify(deep: deep, progress: progress))
        case "doctor": try args.finish(); result(try await vault.checkBots())
        case "bot":
            let action = try args.pop("缺少机器人操作")
            switch action {
            case "list": try args.finish(); try emit(await vault.bots())
            case "add":
                let id = try args.pop("缺少机器人编号"), endpoint = try args.option("--endpoint"); try args.finish()
                let token = try input("Bot Token：", secret: true), chat = try input("Chat ID：")
                try await vault.addBot(id: id, token: token, chatID: chat, endpoint: endpoint); print("机器人已添加")
            case "enable", "disable", "remove":
                let id = try args.pop("缺少机器人编号"); try args.finish(); try await vault.updateBot(id, enabled: action == "remove" ? nil : action == "enable", remove: action == "remove"); print("机器人已更新")
            case "endpoint": let id = try args.pop("缺少机器人编号"), endpoint = try args.pop("缺少 URL（default 恢复默认）"); try args.finish(); try await vault.updateBot(id, endpoint: endpoint == "default" ? "" : endpoint)
            default: throw TASError("未知机器人操作")
            }
        case "sync":
            let action = try args.pop("缺少同步操作")
            switch action {
            case "add": let path = try args.pop("缺少目录"); try args.finish(); try await vault.addFolder(URL(fileURLWithPath: path)); print("同步目录已添加")
            case "remove": let id = Int64(try args.pop("缺少目录 ID")); try args.finish(); guard let id else { throw TASError("目录 ID 无效") }; try await vault.removeFolder(id)
            case "status": try args.finish(); try emit(try await vault.folders())
            case "pull": let path = try args.pop("缺少目标目录"); try args.finish(); result(try await vault.restoreAll(to: URL(fileURLWithPath: path), progress: progress))
            case "start": let watch = args.flag("--watch"); try args.finish(); result(try await vault.resume(progress: progress)); repeat { result(try await vault.sync(progress: progress)); if watch { try await Task.sleep(nanoseconds: 30_000_000_000) } } while watch
            default: throw TASError("未知同步操作")
            }
        default: throw TASError("未知命令：\(command)。运行 tas --help 查看用法。")
        }
    }
}
