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
    TAS 1.2.1 — 原生 Swift Telegram 文件库
    用法：tas <命令> [选项]

      init                       创建文件库，交互输入 Token、Chat ID 和密码
      push <文件...>             上传（--name 路径，--new-version / --replace 保留旧版本，--message 备注）
      pull <ID或完整路径>         下载（--version 正整数 指定历史版本，--output 目标文件）
      history <ID或完整路径>      列出版本历史（--json，含已删除文件）
      restore <ID或完整路径>      恢复为新版本（--version 正整数，--message 备注）；暂停此路径同步
      list | search <关键词>     列出文件（--tag 标签，--deleted 仅已删除，--json）
      delete <ID或完整路径>       软删除并保留历史；已删除文件可用 --hard --yes 永久清除
      tag add|remove <文件> <标签>
      resume                     继续上传（--clear ID 清除任务）
      status                     查看文件、容量和待上传任务（--json）
      bot list|add|enable|disable|remove|endpoint
      index backup|rebuild       备份／恢复加密索引
      verify                     检查远端分块（--all-versions 包含历史，--deep 下载解密并校验）
      sync add <目录> | remove <ID> | status | start [--watch]
      sync resume <文件ID或路径>  解除恢复后的同步暂停；本机内容可能成为新版本
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
    static func identify(_ value: String, vault: Vault, includeDeleted: Bool = false) async throws -> Int64 {
        if let id = Int64(value) { return id }
        // An explicit ./ prefix selects a numeric filename rather than a file ID.
        let path = value.hasPrefix("./") ? String(value.dropFirst(2)) : value
        let matches = try await vault.files(search: path, includeDeleted: includeDeleted).filter { $0.filename == path }
        guard matches.count == 1 else { throw TASError("请使用文件 ID 或唯一的完整逻辑路径；纯数字文件名请加 ./ 前缀") }; return matches[0].id
    }
    static func requireConfirmation(hard: Bool, confirmed: Bool) throws {
        if hard && !confirmed { throw TASError("永久清除全部历史无法撤销；请先软删除，再使用 --hard --yes 确认") }
        if confirmed && !hard { throw TASError("--yes 仅用于 --hard 永久清除") }
    }
    static func versionOption(_ args: inout Arguments, required: Bool = false) throws -> Int? {
        guard let value = try args.option("--version") else {
            if required { throw TASError("缺少 --version 正整数") }; return nil
        }
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }), let version = Int(value), version > 0 else { throw TASError("版本号必须为正整数") }
        return version
    }
    static func run() async throws {
        var args = Arguments(values: Array(CommandLine.arguments.dropFirst()))
        if args.flag("--self-test") { print(try Diagnostics.selfTest()); return }
        if args.flag("--help") || args.values.isEmpty { print(help); return }
        if args.values == ["--version"] { print("tas 1.2.1 (Swift)"); return }
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
            let tag = try args.option("--tag"), deleted = args.flag("--deleted")
            let search = command == "search" ? try args.pop("缺少搜索词") : ""; try args.finish()
            let files = try await vault.files(search: search, tag: tag, includeDeleted: deleted).filter { $0.deleted == deleted }
            if json { try emit(files) } else { for file in files { print("\(file.id)\t\(ByteCountFormatter.string(fromByteCount: file.originalSize, countStyle: .file))\t\(file.filename)\t\(file.tags.joined(separator: ","))") } }
        case "history":
            let id = try await identify(args.pop("缺少文件 ID 或完整路径"), vault: vault, includeDeleted: true); try args.finish()
            let versions = try await vault.history(id)
            if json { try emit(versions) } else {
                for version in versions {
                    print("v\(version.number)\t\(version.isCurrent ? "当前" : "历史")\t\(version.createdAt)\t\(version.originalSize) 字节\t\(version.source)\t\(version.message ?? "")")
                }
            }
        case "push":
            let name = try args.option("--name"), message = try args.option("--message")
            let replace = args.flag("--replace"), newVersion = args.flag("--new-version")
            guard !args.values.isEmpty && (name == nil || args.values.count == 1) else { throw TASError("请提供文件；--name 仅用于单个文件") }
            guard !args.values.contains(where: { $0.hasPrefix("--") }) else { throw TASError("上传参数无法识别") }
            for path in args.values { result(try await vault.upload(URL(fileURLWithPath: path), name: name, replace: replace || newVersion, message: message, progress: progress)) }
        case "pull":
            let output = try args.option("--output"), version = try versionOption(&args)
            let id = try await identify(args.pop("缺少文件 ID"), vault: vault, includeDeleted: true); try args.finish()
            guard let file = try await vault.files(includeDeleted: true).first(where: { $0.id == id }) else { throw TASError("文件不存在") }
            let basename = URL(fileURLWithPath: file.filename).lastPathComponent
            let target = URL(fileURLWithPath: output ?? (version.map { "v\($0)-\(basename)" } ?? basename))
            try await vault.download(id, to: target, version: version, progress: progress); print(target.path)
        case "restore":
            let version = try versionOption(&args, required: true)!
            let message = try args.option("--message")
            let id = try await identify(args.pop("缺少文件 ID 或完整路径"), vault: vault, includeDeleted: true); try args.finish()
            result(try await vault.restoreVersion(id, version: version, message: message, progress: progress))
        case "delete", "rm":
            let hard = args.flag("--hard"), confirmed = args.flag("--yes")
            try requireConfirmation(hard: hard, confirmed: confirmed)
            let id = try await identify(args.pop("缺少文件 ID"), vault: vault, includeDeleted: true); try args.finish()
            result(try await vault.delete(id, hard: hard))
        case "tag":
            let action = try args.pop("缺少 add/remove"); let id = try await identify(args.pop("缺少文件 ID"), vault: vault); let value = try args.pop("缺少标签"); try args.finish()
            guard ["add", "remove"].contains(action) else { throw TASError("请使用 tag add/remove") }; result(try await vault.tag(id, value: value, remove: action == "remove"))
        case "resume":
            if let clear = try args.option("--clear"), let id = Int64(clear) { try args.finish(); result(try await vault.clearPending(id)) }
            else { try args.finish(); result(try await vault.resume(progress: progress)) }
        case "status":
            try args.finish(); let stats = try await vault.statistics(), pending = try await vault.pending()
            struct Status: Encodable { let files: Int; let deletedFiles: Int; let versions: Int; let originalBytes: Int64; let storedBytes: Int64; let historyBytes: Int64; let pending: [PendingUpload]; let manifestDate: String? }
            let status = await Status(files: stats.files, deletedFiles: stats.deletedFiles, versions: stats.versions, originalBytes: stats.originalBytes, storedBytes: stats.storedBytes, historyBytes: stats.historyBytes, pending: pending, manifestDate: vault.manifestDate())
            if json { try emit(status) } else { print("\(status.files) 个文件 · 已删除 \(status.deletedFiles) · 共 \(status.versions) 个版本\n当前原始 \(status.originalBytes) 字节 · 存储 \(status.storedBytes) 字节 · 历史 \(status.historyBytes) 字节\n待上传：\(pending.count)\n索引备份：\(status.manifestDate ?? "尚未备份")") }
        case "index":
            let action = try args.pop("缺少 backup/rebuild"); try args.finish()
            switch action { case "backup": result(try await vault.backupIndex()); case "rebuild": result(try await vault.rebuildIndex()); default: throw TASError("请使用 index backup/rebuild") }
        case "verify":
            let deep = args.flag("--deep"), allVersions = args.flag("--all-versions"); try args.finish()
            result(try await vault.verify(deep: deep, allVersions: allVersions, progress: progress))
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
            case "resume":
                let id = try await identify(args.pop("缺少文件 ID 或完整路径"), vault: vault); try args.finish()
                result(try await vault.resumeSync(id))
            case "status": try args.finish(); try emit(try await vault.folders())
            case "pull": let path = try args.pop("缺少目标目录"); try args.finish(); result(try await vault.restoreAll(to: URL(fileURLWithPath: path), progress: progress))
            case "start": let watch = args.flag("--watch"); try args.finish(); result(try await vault.resume(progress: progress)); repeat { result(try await vault.sync(progress: progress)); if watch { try await Task.sleep(nanoseconds: 30_000_000_000) } } while watch
            default: throw TASError("未知同步操作")
            }
        default: throw TASError("未知命令：\(command)。运行 tas --help 查看用法。")
        }
    }
}
