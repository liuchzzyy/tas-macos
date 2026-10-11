#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TASCore

@MainActor final class AppModel: ObservableObject {
    @Published var vault: Vault?
    @Published var directory = Paths.dataDirectory
    @Published var files: [StoredFile] = []
    @Published var bots: [BotInfo] = []
    @Published var pending: [PendingUpload] = []
    @Published var folders: [SyncFolder] = []
    @Published var manifestDate: String?
    @Published var busy = false
    @Published var progress = TransferProgress("准备就绪")
    @Published var notice: String?
    @Published var logs: [String] = []
    @Published var autoSync = false
    @Published var selectedFileID: StoredFile.ID?
    @Published var historyFile: StoredFile?
    @Published var historyVersions: [FileVersion] = []
    @Published var presentingDialog = false
    private var task: Task<Void, Never>?
    var configured: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) }
    var activeFiles: [StoredFile] { files.filter { !$0.deleted } }
    var totalSize: Int64? { try? checkedByteTotal(activeFiles.map(\.originalSize)) }
    var selection: StoredFile? { files.first { $0.id == selectedFileID } }
    var canOperate: Bool { vault != nil && !busy && !presentingDialog }
    var canUseSelection: Bool { canOperate && historyFile == nil && selection != nil }
    var canUploadVersion: Bool { canUseSelection && selection?.deleted == false }
    var canResumeSync: Bool { canUploadVersion && selection?.syncPaused == true }
    func open(password: String, token: String?, chat: String?, endpoint: String?) {
        guard !busy else { return }; busy = true; notice = nil; progress = TransferProgress("正在解锁文件库")
        let directory = directory
        task = Task {
            do {
                if let token, let chat { try await Vault.create(directory: directory, password: password, token: token, chatID: chat, endpoint: endpoint) }
                let opened = try await Task.detached(priority: .userInitiated) { try Vault(directory: directory, password: password) }.value
                vault = opened; try await refresh(opened); progress = TransferProgress("文件库已解锁")
            } catch { notice = error.localizedDescription }
            busy = false; task = nil
        }
    }
    func lock() {
        guard canOperate && historyFile == nil else { return }
        autoSync = false; vault = nil; files = []; bots = []; pending = []; folders = []; logs = []
        selectedFileID = nil; historyFile = nil; historyVersions = []; progress = TransferProgress("已锁定")
    }
    func refresh(_ vault: Vault) async throws {
        files = try await vault.files(includeDeleted: true); bots = await vault.bots(); pending = try await vault.pending(); folders = try await vault.folders(); manifestDate = await vault.manifestDate()
        if let selectedFileID, !files.contains(where: { $0.id == selectedFileID }) { self.selectedFileID = nil }
        if let target = historyFile {
            historyFile = files.first { $0.id == target.id }
            historyVersions = historyFile == nil ? [] : try await vault.history(target.id).sorted { $0.number > $1.number }
        }
    }
    func run(_ title: String, operation: @escaping (Vault, @escaping ProgressHandler) async throws -> OperationResult) {
        guard let vault, canOperate else { return }
        busy = true; notice = nil; progress = TransferProgress(title)
        task = Task {
            let handler: ProgressHandler = { [weak self] update in Task { @MainActor in self?.progress = update } }
            do {
                let result = try await operation(vault, handler)
                logs.insert("\(Date().formatted(date: .omitted, time: .shortened))  \(result.message)", at: 0)
                progress = TransferProgress(result.message, 1)
                if let warning = result.warning { notice = warning; logs.insert(warning, at: 0) }
            } catch is CancellationError { progress = TransferProgress("任务已取消，可在传输任务中继续上传"); logs.insert("任务已取消", at: 0) }
            catch { notice = error.localizedDescription; logs.insert(error.localizedDescription, at: 0); progress = TransferProgress("任务未完成") }
            do { try await refresh(vault) } catch { notice = error.localizedDescription; progress = TransferProgress("刷新文件库失败") }
            busy = false; task = nil
        }
    }
    func cancel() { task?.cancel() }
    func upload(_ urls: [URL]) {
        guard canOperate, historyFile == nil, !urls.isEmpty else { return }
        presentingDialog = true
        let requests = prepareUploads(urls)
        presentingDialog = false
        guard let requests else { return }
        run("准备上传") { vault, progress in
            var warnings: [String] = []
            for request in requests {
                try Task.checkCancellation()
                let result = try await vault.upload(request.url, name: request.name, replace: request.replace, message: request.message, progress: progress)
                if let warning = result.warning { warnings.append(warning) }
            }
            return OperationResult("已上传 \(requests.count) 个文件", warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
        }
    }
    func chooseUpload() {
        guard canOperate, historyFile == nil else { return }
        presentingDialog = true
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.prompt = "上传"
        let response = panel.runModal()
        presentingDialog = false
        if response == .OK { upload(panel.urls) }
    }
    func download(_ file: StoredFile, version: Int? = nil) {
        guard canOperate, files.contains(where: { $0.id == file.id }) else { return }
        presentingDialog = true
        let panel = NSSavePanel(); panel.nameFieldStringValue = version.map { versionedFilename(file.filename, version: $0) } ?? URL(fileURLWithPath: file.filename).lastPathComponent; panel.prompt = "下载"
        let response = panel.runModal()
        presentingDialog = false
        guard response == .OK, let destination = panel.url else { return }
        run("准备下载") { vault, progress in try await vault.download(file.id, to: destination, version: version, progress: progress); return OperationResult("已下载 \(file.filename)\(version.map { " · v\($0)" } ?? "")") }
    }
    func addFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "添加同步目录"
        if panel.runModal() == .OK, let url = panel.url { run("添加目录") { vault, _ in try await vault.addFolder(url); return OperationResult("已添加同步目录") } }
    }
    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.directoryURL = directory; panel.prompt = "选择文件库目录"
        if panel.runModal() == .OK, let url = panel.url { directory = url }
    }
    func restoreAll() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "恢复到此目录"
        if panel.runModal() == .OK, let url = panel.url {
            let alert = NSAlert(); alert.messageText = "恢复全部文件？"; alert.informativeText = "将按文件库中的路径写入所选目录。同名文件在校验通过后会被替换。"; alert.addButton(withTitle: "恢复"); alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { run("恢复文件") { vault, progress in try await vault.restoreAll(to: url, progress: progress) } }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct TASApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    init() {
        if CommandLine.arguments.contains("--smoke-test") {
            do { print(try Diagnostics.selfTest()); exit(0) }
            catch { fputs("Self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup("TAS") {
            RootView().environmentObject(model).frame(minWidth: 960, minHeight: 650)
                .tint(Color(red: 0.15, green: 0.48, blue: 0.40))
                .alert("TAS", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) { Button("知道了") { model.notice = nil } } message: { Text(model.notice ?? "") }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { Button("上传文件…") { model.chooseUpload() }.keyboardShortcut("u").disabled(!model.canOperate || model.historyFile != nil) }
            CommandMenu("文件库") {
                Button("上传新版本…") { if let file = model.selection { model.chooseNewVersion(file) } }.disabled(!model.canUploadVersion)
                Button("版本历史…") { if let file = model.selection { model.showHistory(file) } }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!model.canUseSelection)
                Button("恢复自动同步…") { if let file = model.selection { model.resumeFileSync(file) } }.disabled(!model.canResumeSync)
                Divider()
                Button("删除并保留历史…") { if let file = model.selection { model.deleteFile(file) } }.disabled(!model.canUploadVersion)
                Button("永久清除…", role: .destructive) { if let file = model.selection { model.deleteFile(file, permanently: true) } }.disabled(!model.canUseSelection || model.selection?.deleted != true)
                Divider()
                Button("锁定文件库") { model.lock() }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(!model.canOperate || model.historyFile != nil)
                Button("备份索引") { model.run("备份索引") { vault, _ in try await vault.backupIndex() } }.disabled(!model.canOperate || model.historyFile != nil)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: String? = "files"
    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var body: some View {
        Group {
            if model.vault == nil { UnlockView() }
            else {
                NavigationSplitView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 11) {
                            Image(systemName: "shippingbox.fill").font(.system(size: 27)).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) { Text("TAS").font(.title2.bold()); Text("你的加密文件库").font(.caption).foregroundStyle(.secondary) }
                        }.padding(22)
                        List(selection: $section) {
                            Label("所有文件", systemImage: "folder").tag("files")
                            Label("已删除", systemImage: "trash").tag("deleted")
                            Label("传输任务", systemImage: "arrow.up.arrow.down").tag("transfers")
                            Label("文件夹同步", systemImage: "arrow.triangle.2.circlepath").tag("sync")
                            Label("设置", systemImage: "slider.horizontal.3").tag("settings")
                        }.listStyle(.sidebar)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("文件库已解锁", systemImage: "lock.open").font(.caption).foregroundStyle(.secondary)
                            Text("\(model.activeFiles.count) 个文件 · \(model.totalSize.map(bytes) ?? "大小无效")").font(.caption)
                            Button { model.lock() } label: { Label("锁定文件库", systemImage: "lock") }.disabled(model.busy)
                        }.padding(20)
                    }.navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 260)
                } detail: {
                    VStack(spacing: 0) {
                        Group {
                            switch section {
                            case "transfers": TransfersView()
                            case "sync": SyncView()
                            case "settings": SettingsView()
                            case "deleted": LibraryView(showDeleted: true).id("deleted")
                            default: LibraryView().id("files")
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        HStack(spacing: 12) {
                            if model.busy { ProgressView().controlSize(.small) }
                            else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                            Text(model.progress.message).font(.caption).lineLimit(1)
                            Spacer()
                            if model.busy {
                                if let fraction = model.progress.fraction { ProgressView(value: fraction).frame(width: 130) }
                                Button("取消") { model.cancel() }.controlSize(.small)
                            }
                        }.padding(.horizontal, 22).frame(height: 43)
                    }
                }
            }
        }
        .sheet(item: $model.historyFile, onDismiss: { model.historyVersions = [] }) { file in
            VersionHistoryView(fileID: file.id).environmentObject(model)
        }
        .onChange(of: section) { _ in model.selectedFileID = nil }
        .onReceive(timer) { _ in if model.autoSync && model.canOperate && model.historyFile == nil { model.run("自动同步") { vault, progress in try await vault.sync(progress: progress) } } }
    }
}

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var confirmation = ""
    @State private var token = ""
    @State private var chat = ""
    @State private var endpoint = ""
    var body: some View {
        HStack(spacing: 70) {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "shippingbox.fill").font(.system(size: 58)).foregroundStyle(.tint)
                Text("文件归你。\n随时取回。").font(.system(size: 40, weight: .semibold)).lineSpacing(7)
                Text("TAS for Mac").font(.title3).foregroundStyle(.secondary)
                Text("文件在本机加密后上传到 Telegram。\n原生界面，轻装运行。").foregroundStyle(.secondary).lineSpacing(6)
            }.frame(width: 355, alignment: .leading)
            VStack(alignment: .leading, spacing: 18) {
                Text(model.configured ? "解锁文件库" : "创建你的文件库").font(.title2.bold())
                Text(model.configured ? "输入现有 TAS 密码，继续访问你的文件。" : "准备好 Telegram 机器人和私聊或群组的 Chat ID。请先向机器人发送 /start。").foregroundStyle(.secondary).font(.callout)
                if !model.configured {
                    SecureField("Bot Token", text: $token)
                    TextField("Chat ID", text: $chat)
                    TextField("自定义 Bot API 地址（可选）", text: $endpoint)
                }
                SecureField("加密密码", text: $password).onSubmit(submit)
                if !model.configured {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(PasswordPolicy.checks(password), id: \.0) { rule in
                            Label(rule.0, systemImage: rule.1 ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(rule.1 ? Color.green : Color.secondary)
                        }
                    }.font(.caption).accessibilityElement(children: .combine)
                    SecureField("再次输入密码", text: $confirmation)
                    if !confirmation.isEmpty {
                        Label(password == confirmation ? "两次密码一致" : "两次密码不一致", systemImage: password == confirmation ? "checkmark.circle.fill" : "circle")
                            .font(.caption).foregroundStyle(password == confirmation ? Color.green : Color.secondary)
                    }
                }
                Button(action: submit) {
                    HStack { Spacer(); if model.busy { ProgressView().controlSize(.small) }; Text(model.configured ? "解锁" : "创建文件库"); Spacer() }.padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).disabled(model.busy || password.isEmpty || (!model.configured && (!PasswordPolicy.isValid(password) || password != confirmation)))
                Divider()
                Text("文件库目录").font(.caption).foregroundStyle(.secondary)
                HStack { Text(model.directory.path).font(.caption).lineLimit(1).truncationMode(.middle); Spacer(); Button("更改…") { model.chooseDirectory() }.disabled(model.busy) }
                Text("旧版默认使用 ~/.tas。请保管好密码和 config.json，它们用于解密与恢复索引。").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }.textFieldStyle(.roundedBorder).frame(width: 340).padding(32).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }.padding(44).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
    private func submit() {
        if !model.configured && !PasswordPolicy.isValid(password) { model.notice = "密码尚未满足全部要求"; return }
        if !model.configured && password != confirmation { model.notice = "两次输入的密码不一致"; return }
        model.open(password: password, token: model.configured ? nil : token, chat: model.configured ? nil : chat, endpoint: endpoint.isEmpty ? nil : endpoint)
        password = ""; confirmation = ""; token = ""
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    var showDeleted = false
    @State private var search = ""
    @State private var targeted = false
    @State private var tagging: StoredFile?
    @State private var tag = ""
    @State private var removeTag = false
    var filtered: [StoredFile] { model.files.filter { $0.deleted == showDeleted && (search.isEmpty || $0.filename.localizedCaseInsensitiveContains(search) || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) })) } }
    var selection: StoredFile? { filtered.first { $0.id == model.selectedFileID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 7) { Text(showDeleted ? "已删除" : "所有文件").font(.largeTitle.bold()); Text(showDeleted ? "全部历史仍然保留，可选择版本恢复文件。" : "上传、查找和取回你的文件。").foregroundStyle(.secondary) }
                Spacer()
                Button { model.chooseUpload() } label: { Label("上传文件", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canOperate)
            }
            HStack(spacing: 16) {
                Metric(title: showDeleted ? "已删除" : "文件", value: "\(model.files.filter { $0.deleted == showDeleted }.count)", icon: "doc.on.doc")
                Metric(title: "原始大小", value: (try? checkedByteTotal(model.files.filter { $0.deleted == showDeleted }.map(\.originalSize))).map(bytes) ?? "大小无效", icon: "externaldrive")
                Metric(title: "待续传", value: "\(model.pending.count)", icon: "arrow.up.circle")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文件名或标签", text: $search).textFieldStyle(.plain)
                Spacer()
                if let selection {
                    Button { model.download(selection) } label: { Image(systemName: "arrow.down.to.line") }.help("下载当前版本").accessibilityLabel("下载当前版本").disabled(!model.canOperate)
                    Button { model.showHistory(selection) } label: { Label("版本历史", systemImage: "clock.arrow.circlepath") }.disabled(!model.canUseSelection)
                    if !selection.deleted {
                        Button { model.chooseNewVersion(selection) } label: { Image(systemName: "doc.badge.plus") }.help("上传新版本").accessibilityLabel("上传新版本").disabled(!model.canUploadVersion)
                        Button { tagging = selection; model.presentingDialog = true } label: { Image(systemName: "tag") }.help("编辑标签").accessibilityLabel("编辑标签").disabled(!model.canOperate)
                        if selection.syncPaused {
                            Button { model.resumeFileSync(selection) } label: { Image(systemName: "play.circle") }.help("恢复自动同步").accessibilityLabel("恢复自动同步").disabled(!model.canResumeSync)
                        }
                    }
                    Button(role: .destructive) { model.deleteFile(selection, permanently: selection.deleted) } label: { Image(systemName: selection.deleted ? "trash.slash" : "trash") }.help(selection.deleted ? "永久清除" : "删除并保留历史").accessibilityLabel(selection.deleted ? "永久清除" : "删除并保留历史").disabled(!model.canUseSelection)
                }
            }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            if filtered.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: search.isEmpty ? "tray.and.arrow.up" : "magnifyingglass").font(.system(size: 43, weight: .light)).foregroundStyle(.secondary)
                    Text(search.isEmpty ? (showDeleted ? "没有已删除的文件" : "把文件拖到这里") : "没有找到文件").font(.title3.weight(.medium))
                    Text(search.isEmpty ? (showDeleted ? "删除的文件会保留版本历史。" : "也可以点击“上传文件”开始。") : "试试其他文件名或标签。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filtered, selection: $model.selectedFileID) {
                    TableColumn("文件名") { file in HStack(spacing: 9) { Image(systemName: file.deleted ? "trash" : "doc").foregroundStyle(.tint); VStack(alignment: .leading, spacing: 3) { Text(file.filename).lineLimit(1); if !file.tags.isEmpty { Text(file.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }; if file.syncPaused { Label("自动同步已暂停", systemImage: "pause.circle").font(.caption).foregroundStyle(.orange) } } } }.width(min: 180, ideal: 290)
                    TableColumn("版本") { Text("v\($0.versionNumber) · 共 \($0.versionCount)").monospacedDigit() }.width(95)
                    TableColumn("大小") { Text(bytes($0.originalSize)).monospacedDigit() }.width(95)
                    TableColumn("更新时间") { Text(String($0.updatedAt.prefix(16)).replacingOccurrences(of: "T", with: " ")).foregroundStyle(.secondary) }.width(140)
                }.contextMenu(forSelectionType: StoredFile.ID.self) { ids in
                    if ids.count == 1, let id = ids.first, let file = filtered.first(where: { $0.id == id }) {
                        Button("下载…") { model.download(file) }
                        Button("版本历史…") { model.showHistory(file) }
                        if !file.deleted {
                            Button("上传新版本…") { model.chooseNewVersion(file) }
                            Button("编辑标签…") { tagging = file; model.presentingDialog = true }
                            Button("恢复自动同步…") { model.resumeFileSync(file) }.disabled(!file.syncPaused)
                        }
                        Divider()
                        Button(file.deleted ? "永久清除…" : "删除并保留历史…", role: .destructive) { model.deleteFile(file, permanently: file.deleted) }
                    }
                }.disabled(!model.canOperate)
            }
        }.padding(28)
        .overlay { if targeted { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(10).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            guard model.canOperate, model.historyFile == nil, !showDeleted else { return false }
            let session = model.vault
            Task {
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                            else { continuation.resume(returning: item as? URL) }
                        }
                    }
                    if let url { urls.append(url) }
                }
                if model.vault === session, !urls.isEmpty { model.upload(urls) }
            }
            return true
        }
        .onChange(of: filtered.map(\.id)) { ids in if let id = model.selectedFileID, !ids.contains(id) { model.selectedFileID = nil } }
        .onDisappear { model.selectedFileID = nil }
        .sheet(item: $tagging, onDismiss: { model.presentingDialog = false }) { target in
            VStack(alignment: .leading, spacing: 18) {
                Text("编辑标签").font(.title2.bold())
                Text(target.filename).foregroundStyle(.secondary)
                TextField("标签", text: $tag).textFieldStyle(.roundedBorder)
                Toggle("移除此标签", isOn: $removeTag)
                HStack { Spacer(); Button("取消") { tagging = nil }; Button("保存") { let value = tag, remove = removeTag; model.presentingDialog = false; model.run("更新标签") { vault, _ in try await vault.tag(target.id, value: value, remove: remove) }; tagging = nil }.buttonStyle(.borderedProminent).disabled(tag.isEmpty || model.busy || model.vault == nil) }
            }.padding(28).frame(width: 360)
        }
    }

}
struct Metric: View {
    let title: String; let value: String; let icon: String
    var body: some View { VStack(alignment: .leading, spacing: 14) { Label(title, systemImage: icon).font(.callout).foregroundStyle(.secondary); Text(value).font(.title2.weight(.semibold)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)) }
}
struct TransfersView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("传输任务").font(.largeTitle.bold()); Spacer(); Button("继续全部上传") { model.run("继续上传") { vault, progress in try await vault.resume(progress: progress) } }.buttonStyle(.borderedProminent).disabled(model.busy || model.pending.isEmpty) }
            Text("中断的上传保留加密分块，可以在下次打开时继续。").foregroundStyle(.secondary)
            List {
                Section("待续传") {
                    if model.pending.isEmpty { Text("没有待续传的任务").foregroundStyle(.secondary) }
                    ForEach(model.pending) { item in
                        HStack { Image(systemName: "arrow.up.doc"); VStack(alignment: .leading, spacing: 5) { Text(item.filename); Text("已上传 \(item.uploaded) / \(item.total) 个分块").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("清除") { clear(item) }.disabled(model.busy) }.padding(.vertical, 6)
                    }
                }
                Section("本次会话") { if model.logs.isEmpty { Text("还没有传输记录").foregroundStyle(.secondary) }; ForEach(Array(model.logs.enumerated()), id: \.offset) { _, log in Text(log).font(.callout).textSelection(.enabled) } }
            }.listStyle(.inset)
        }.padding(28)
    }
    private func clear(_ item: PendingUpload) {
        let alert = NSAlert(); alert.messageText = "清除“\(item.filename)”的上传任务？"; alert.informativeText = "已暂存的加密分块将被移除，之后需要重新上传源文件。"; alert.addButton(withTitle: "清除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.run("清除任务") { vault, _ in try await vault.clearPending(item.id) } }
    }
}
struct SyncView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("文件夹同步").font(.largeTitle.bold()); Spacer(); Button("添加目录…") { model.addFolder() }.disabled(model.busy); Button("立即同步") { model.run("同步文件夹") { vault, progress in try await vault.sync(progress: progress) } }.buttonStyle(.borderedProminent).disabled(model.busy || model.folders.isEmpty) }
            Text("按相对路径上传新增文件，修改内容会保存为新版本。本地删除不会删除远端文件；多个同步目录出现相同相对路径时会报告冲突，并在上传前停止本轮同步。恢复历史后，该文件的自动同步会暂停；可在文件列表中明确恢复。").foregroundStyle(.secondary)
            Toggle("应用打开时，每 30 秒检查一次变化", isOn: $model.autoSync).disabled(model.folders.isEmpty)
            List(model.folders) { folder in HStack { Image(systemName: "folder").foregroundStyle(.tint); Text(folder.path).textSelection(.enabled); Spacer(); Button("移除") { model.run("移除同步目录") { vault, _ in try await vault.removeFolder(folder.id); return OperationResult("已移除同步目录") } }.disabled(model.busy) }.padding(.vertical, 8) }
            HStack { Text("需要在另一台 Mac 取回文件？").foregroundStyle(.secondary); Spacer(); Button("恢复全部文件…") { model.restoreAll() }.disabled(model.busy) }
        }.padding(28)
    }
}
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var addingBot = false
    @State private var editingBot: BotInfo?
    @State private var checkingUpdate = false
    @State private var updateStatus: String?
    @State private var latestRelease: ReleaseUpdate?
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    private var gitHash: String { Bundle.main.object(forInfoDictionaryKey: "TASGitHash") as? String ?? "unknown" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("设置").font(.largeTitle.bold())
                GroupBox {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("文件库").font(.headline)
                        Text(model.directory.path).textSelection(.enabled).foregroundStyle(.secondary)
                        Text("最近索引备份：\(model.manifestDate ?? "尚未备份")").font(.callout)
                        HStack {
                            Button("备份索引") { model.run("备份索引") { vault, _ in try await vault.backupIndex() } }
                            Button("恢复索引…") { rebuild() }
                            Button("检查连接") { model.run("检查连接") { vault, _ in try await vault.checkBots() } }
                            Button("完整校验") { model.run("完整校验") { vault, progress in try await vault.verify(deep: true, progress: progress) } }
                            Button("校验全部历史") { model.run("校验全部历史") { vault, progress in try await vault.verify(deep: true, allVersions: true, progress: progress) } }
                        }.disabled(model.busy)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { Text("Telegram 机器人").font(.headline); Spacer(); Button("添加…") { addingBot = true }.disabled(model.busy) }
                        ForEach(model.bots) { bot in
                            HStack {
                                Image(systemName: "paperplane.circle.fill").font(.title2).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 4) { Text(bot.username.isEmpty ? bot.id : "@\(bot.username)").fontWeight(.medium); Text("\(bot.id) · \(bot.chatID)").font(.caption).foregroundStyle(.secondary); if let endpoint = bot.endpoint { Text(endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
                                Spacer()
                                Button("API 地址…") { editingBot = bot }.disabled(model.busy)
                                Toggle("启用", isOn: Binding(get: { bot.enabled }, set: { enabled in model.run("更新机器人") { vault, _ in try await vault.updateBot(bot.id, enabled: enabled); return OperationResult("机器人已更新") } })).toggleStyle(.switch).fixedSize().disabled(model.busy)
                            }.padding(.vertical, 7)
                        }
                    }.padding(12)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("软件更新").font(.headline)
                            Spacer()
                            Button("检查更新") { Task { await checkForUpdates() } }.disabled(checkingUpdate)
                        }
                        if checkingUpdate { ProgressView("正在检查 GitHub 最新 Release…").controlSize(.small) }
                        if let updateStatus { Text(updateStatus).font(.callout).foregroundStyle(.secondary) }
                        if let latestRelease {
                            Link("查看 TAS \(latestRelease.version) Release", destination: latestRelease.releaseURL)
                        }
                        Link("在浏览器查看最新 Releases", destination: URL(string: "https://github.com/liuchzzyy/tas-macos/releases/latest")!)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                Text("TAS \(appVersion) · \(gitHash)").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.sheet(isPresented: $addingBot) { AddBotView() }.sheet(item: $editingBot) { bot in EndpointView(bot: bot) }
    }
    private func checkForUpdates() async {
        guard !checkingUpdate else { return }
        checkingUpdate = true; updateStatus = nil; latestRelease = nil
        defer { checkingUpdate = false }
        var cliError: String?
        // A private GitHub repo returns 404 without authentication. Use the user's
        // existing gh login if available, and fall back to the public API otherwise.
        if let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            do {
                let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: gh)
                    process.arguments = ["api", "repos/liuchzzyy/tas-macos/releases/latest"]
                    process.environment = ProcessInfo.processInfo.environment.merging(["GH_HTTP_TIMEOUT": "15"]) { _, new in new }
                    let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw NSError(domain: "TAS.Update", code: 3) }
                    return data
                }.value
                showRelease(try ReleaseUpdate(data: data))
                return
            } catch {
                cliError = error.localizedDescription
            }
        }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/liuchzzyy/tas-macos/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("TAS-macOS", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw NSError(domain: "TAS.Update", code: 2, userInfo: [NSLocalizedDescriptionKey: "无效的服务器响应"]) }
            if response.statusCode == 404 {
                updateStatus = "仓库为私有或尚未发布 Release：请确认 gh 已登录且拥有仓库权限，或在浏览器查看 Releases。"; return
            }
            guard response.statusCode == 200 else { throw NSError(domain: "TAS.Update", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub 返回 HTTP \(response.statusCode)"]) }
            showRelease(try ReleaseUpdate(data: data))
        } catch { updateStatus = "检查更新失败：\(cliError.map { "gh：\($0)；" } ?? "")\(error.localizedDescription)" }
    }
    private func showRelease(_ release: ReleaseUpdate) {
        if release.isNewer(than: appVersion) {
            updateStatus = "发现新版本 TAS \(release.version)（当前 \(appVersion)）"
            latestRelease = release
        } else { updateStatus = "已是最新版本（\(appVersion)）" }
    }
    private func rebuild() {
        let alert = NSAlert(); alert.messageText = "从远端恢复索引？"; alert.informativeText = "当前索引会先备份到文件库目录，再由最近一次远端备份替换。尚未进入备份的文件不会显示在恢复后的索引中。"; alert.addButton(withTitle: "备份并恢复"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.run("恢复索引") { vault, _ in try await vault.rebuildIndex() } }
    }
}
struct AddBotView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""; @State private var token = ""; @State private var chat = ""; @State private var endpoint = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加机器人").font(.title2.bold()); TextField("编号，例如 backup", text: $id); SecureField("Bot Token", text: $token); TextField("Chat ID", text: $chat); TextField("自定义 Bot API 地址（可选）", text: $endpoint)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("连接并添加") { let id = id, token = token, chat = chat, endpoint = endpoint; model.run("验证机器人") { vault, _ in try await vault.addBot(id: id, token: token, chatID: chat, endpoint: endpoint.isEmpty ? nil : endpoint); return OperationResult("机器人已添加") }; dismiss() }.buttonStyle(.borderedProminent).disabled(id.isEmpty || token.isEmpty || chat.isEmpty) }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 400)
    }
}
struct EndpointView: View {
    let bot: BotInfo
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bot API 地址").font(.title2.bold()); Text(bot.id).foregroundStyle(.secondary)
            TextField("留空使用 https://api.telegram.org", text: $endpoint).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") { let value = endpoint; model.run("更新 API 地址") { vault, _ in try await vault.updateBot(bot.id, endpoint: value); return OperationResult("API 地址已更新") }; dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 430).onAppear { endpoint = bot.endpoint ?? "" }
    }
}
func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
#else
import Foundation
@main struct UnsupportedHost { static func main() { fputs("TAS.app requires macOS 13 or later. Use the tas CLI on this platform.\n", stderr) } }
#endif
