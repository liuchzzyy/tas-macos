#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TASCore

@MainActor final class AppModel: ObservableObject {
    @Published var vault: Vault?
    #if TAS_UI_PREVIEW
    @Published var directory = FileManager.default.temporaryDirectory.appendingPathComponent("tas-ui-preview-\(UUID().uuidString)")
    #else
    @Published var directory = Paths.dataDirectory
    #endif
    @Published var files: [StoredFile] = []
    @Published var bots: [BotInfo] = []
    @Published var pending: [PendingUpload] = []
    @Published var folders: [SyncFolder] = []
    @Published var manifestDate: String?
    @Published var statistics: VaultStatistics?
    @Published var busy = false
    @Published var progress = TransferProgress(L10n.tr("准备就绪"))
    @Published var notice: String?
    @Published var logs = SessionLog()
    @Published var autoSync = false
    /// Mirrors whether a keychain copy exists, so views never touch the keychain
    /// while rendering.
    @Published var passwordStored = false
    @Published var selectedFileID: StoredFile.ID?
    @Published var historyFile: StoredFile?
    @Published var historyVersions: [FileVersion] = []
    @Published private var presentingNativeDialog = false
    var presentingDialog: Bool {
        get { presentingNativeDialog || settingsDialog.isPresented }
        set { presentingNativeDialog = newValue }
    }
    @Published private var settingsDialog = SettingsDialogCoordinator()
    private var task: Task<Void, Never>?
    /// Auto-unlock runs once per vault directory so a failed attempt cannot loop.
    private var autoUnlockAttemptedDirectory: String?
    /// In-memory only: lets "remember password" take effect without a re-unlock.
    /// Never written anywhere except the keychain, and dropped when the vault locks.
    private var sessionPassword: String?
    init() {}
    var configured: Bool {
        #if TAS_UI_PREVIEW
        false
        #else
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path)
        #endif
    }
    var activeFiles: [StoredFile] { files.filter { !$0.deleted } }
    var totalSize: Int64? { try? checkedByteTotal(activeFiles.map(\.originalSize)) }
    var selection: StoredFile? { files.first { $0.id == selectedFileID } }
    var canOperate: Bool {
        #if TAS_UI_PREVIEW
        false
        #else
        vault != nil && !busy && !presentingDialog && settingsDialog.allowsBackgroundOperation
        #endif
    }
    var canSubmitSettingsDialog: Bool {
        #if TAS_UI_PREVIEW
        false
        #else
        settingsDialog.canSubmit(connected: vault != nil, busy: busy, otherDialog: presentingNativeDialog)
        #endif
    }
    func beginSettingsDialog() -> Bool {
        guard canOperate, historyFile == nil else { return false }
        return settingsDialog.reserve(connected: vault != nil, busy: busy, otherDialog: presentingDialog)
    }
    func endSettingsDialog() { settingsDialog.dismiss() }
    @discardableResult
    func submitSettingsDialog(_ title: String, operation: @escaping (Vault, @escaping ProgressHandler) async throws -> OperationResult) -> Bool {
        run(title, fromSettingsDialog: true, operation: operation)
    }
    var canUseSelection: Bool { canOperate && historyFile == nil && selection != nil }
    var canUploadVersion: Bool { canUseSelection && selection?.deleted == false }
    var canResumeSync: Bool { canUploadVersion && selection?.syncPaused == true }
    func open(password: String, token: String?, chat: String?, endpoint: String?, fromKeychain: Bool = false) {
        #if !TAS_UI_PREVIEW
        guard !busy else { return }; busy = true; notice = nil; progress = TransferProgress(L10n.tr("正在解锁文件库"))
        let directory = directory
        task = Task {
            do {
                if let token, let chat { try await Vault.create(directory: directory, password: password, token: token, chatID: chat, endpoint: endpoint) }
                let opened = try await Task.detached(priority: .userInitiated) { try Vault(directory: directory, password: password) }.value
                try await refresh(opened)
                vault = opened; progress = TransferProgress(L10n.tr("文件库已解锁"))
                sessionPassword = password
                if AppPreferences.shared.rememberPassword {
                    passwordStored = KeychainStore.save(password, for: directory)
                    if !passwordStored { notice = L10n.tr("无法存入系统钥匙串；请检查钥匙串访问权限。") }
                } else { passwordStored = false }
            } catch {
                notice = error.localizedDescription
                // Wrong passwords must never overwrite a valid keychain credential.
                // Lock or index errors leave the saved credential intact.
                if fromKeychain && error.localizedDescription == "密码不正确" {
                    KeychainStore.delete(for: directory)
                    passwordStored = false
                }
            }
            busy = false; task = nil
        }
        #endif
    }
    /// Reopens the vault from the keychain when the user asked to remember the
    /// password. Attempted once per directory; any failure falls back to the form.
    func autoUnlockIfNeeded() {
        #if !TAS_UI_PREVIEW
        guard vault == nil, !busy, configured, AppPreferences.shared.rememberPassword else { return }
        let directory = directory
        let identity = KeychainStore.account(for: directory)
        guard autoUnlockAttemptedDirectory != identity else { return }
        autoUnlockAttemptedDirectory = identity
        guard let password = KeychainStore.read(for: directory) else { return }
        passwordStored = true
        open(password: password, token: nil, chat: nil, endpoint: nil, fromKeychain: true)
        #endif
    }
    /// Applies the "remember password" choice. Enabling it stores the password of
    /// the current session; disabling it removes the stored copy immediately.
    func setRememberPassword(_ enabled: Bool) {
        #if !TAS_UI_PREVIEW
        AppPreferences.shared.rememberPassword = enabled
        guard enabled else {
            KeychainStore.delete(for: directory); passwordStored = false; return
        }
        guard let sessionPassword else {
            passwordStored = false
            notice = L10n.tr("将在下次解锁后记住密码。")
            return
        }
        passwordStored = KeychainStore.save(sessionPassword, for: directory)
        if !passwordStored { notice = L10n.tr("无法存入系统钥匙串；请检查钥匙串访问权限。") }
        #endif
    }
    func updateRememberedPasswordAfterChange(_ password: String) {
        sessionPassword = password
        if AppPreferences.shared.rememberPassword {
            passwordStored = KeychainStore.save(password, for: directory)
            if !passwordStored {
                KeychainStore.delete(for: directory)
                notice = L10n.tr("密码已更改，但无法存入系统钥匙串；下次需要手动解锁。")
            }
        } else {
            KeychainStore.delete(for: directory)
            passwordStored = false
        }
    }
    func forgetStoredPassword() {
        #if !TAS_UI_PREVIEW
        KeychainStore.delete(for: directory)
        AppPreferences.shared.rememberPassword = false
        passwordStored = false
        if vault != nil { notice = L10n.tr("已忘记保存的密码；下次启动需要重新输入。") }
        #endif
    }
    func lock() {
        guard canOperate && historyFile == nil else { return }
        autoUnlockAttemptedDirectory = KeychainStore.account(for: directory)
        autoSync = false; vault = nil; files = []; bots = []; pending = []; folders = []; logs.clear(); statistics = nil; manifestDate = nil
        sessionPassword = nil
        L10n.clearMessages()
        selectedFileID = nil; historyFile = nil; historyVersions = []; progress = TransferProgress(L10n.tr("已锁定"))
    }
    func refresh(_ vault: Vault) async throws {
        files = try await vault.files(includeDeleted: true); bots = await vault.bots(); pending = try await vault.pending(); folders = try await vault.folders(); statistics = try await vault.statistics(); manifestDate = await vault.manifestDate()
        if let selectedFileID, !files.contains(where: { $0.id == selectedFileID }) { self.selectedFileID = nil }
        if let target = historyFile {
            historyFile = files.first { $0.id == target.id }
            historyVersions = historyFile == nil ? [] : try await vault.history(target.id).sorted { $0.number > $1.number }
        }
    }
    @discardableResult
    func run(_ title: String, fromSettingsDialog: Bool = false, operation: @escaping (Vault, @escaping ProgressHandler) async throws -> OperationResult) -> Bool {
        guard let vault, fromSettingsDialog ? canSubmitSettingsDialog : canOperate else { return false }
        busy = true; notice = nil; progress = TransferProgress(title)
        task = Task {
            let handler: ProgressHandler = { [weak self] update in Task { @MainActor in self?.progress = update } }
            do {
                let result = try await operation(vault, handler)
                logs.append(result.message)
                progress = TransferProgress(result.message, 1)
                if let warning = result.warning { notice = warning; logs.append(warning) }
            } catch is CancellationError { progress = TransferProgress(L10n.tr("任务已取消，可在传输任务中继续上传")); logs.append(L10n.tr("任务已取消")) }
            catch { notice = error.localizedDescription; logs.append(error.localizedDescription); progress = TransferProgress(L10n.tr("任务未完成")) }
            do { try await refresh(vault) } catch { notice = error.localizedDescription; progress = TransferProgress(L10n.tr("刷新文件库失败")) }
            busy = false; task = nil
        }
        return true
    }
    func cancel() { task?.cancel() }
    func upload(_ urls: [URL]) {
        guard canOperate, historyFile == nil, !urls.isEmpty, let session = vault else { return }
        busy = true; notice = nil; progress = TransferProgress(L10n.tr("正在检查上传内容"))
        task = Task {
            let collector = Task.detached(priority: .userInitiated) { try UploadPlan.collect(urls) }
            do {
                let candidates = try await withTaskCancellationHandler {
                    try await collector.value
                } onCancel: { collector.cancel() }
                try Task.checkCancellation()
                guard vault === session else { busy = false; task = nil; return }
                busy = false; task = nil
                guard !candidates.isEmpty else {
                    notice = L10n.tr("没有可上传的文件。文件夹内隐藏项会跳过，空文件夹不单独保存。")
                    progress = TransferProgress(L10n.tr("没有可上传的文件")); return
                }
                presentingDialog = true
                defer { presentingDialog = false }
                let summary = NSAlert()
                summary.messageText = L10n.tr("上传 %@ 个文件？", String(describing: candidates.count))
                summary.informativeText = candidates.prefix(5).map(\.name).joined(separator: "\n")
                    + (candidates.count > 5 ? "\n…" : "")
                    + L10n.tr("\n\n文件夹保留顶层目录与子目录；跳过目录内隐藏项，不保存空文件夹。不添加持续同步任务。")
                summary.addButton(withTitle: L10n.tr("继续")); summary.addButton(withTitle: L10n.tr("取消"))
                guard summary.runModal() == .alertFirstButtonReturn,
                      let requests = prepareUploads(candidates) else { progress = TransferProgress(L10n.tr("已取消上传")); return }
                presentingDialog = false
                run(L10n.tr("准备上传")) { vault, progress in
                    var warnings: [String] = []
                    for (index, request) in requests.enumerated() {
                        try Task.checkCancellation()
                        progress(TransferProgress(L10n.tr("上传 %@/%@ · %@", String(describing: index + 1), String(describing: requests.count), String(describing: request.name))))
                        let result = try await vault.upload(request.url, name: request.name, replace: request.replace, message: request.message, progress: progress)
                        if let warning = result.warning { warnings.append(warning) }
                    }
                    return OperationResult(L10n.tr("已处理 %@ 个文件", String(describing: requests.count)), warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
                }
            } catch {
                busy = false; task = nil
                if error is CancellationError { progress = TransferProgress(L10n.tr("已取消上传检查")) }
                else { notice = error.localizedDescription; progress = TransferProgress(L10n.tr("上传检查未通过，未开始上传")) }
            }
        }
    }
    func chooseUpload() {
        guard canOperate, historyFile == nil else { return }
        presentingDialog = true
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.prompt = L10n.tr("选择上传内容")
        panel.message = L10n.tr("选择要一次性上传的文件或文件夹；文件夹不会加入持续同步。")
        let response = panel.runModal()
        presentingDialog = false
        if response == .OK {
            do { try UploadKind.filesAndFolders.validate(panel.urls); upload(panel.urls) }
            catch { notice = error.localizedDescription }
        }
    }
    func acceptUploadDrop(_ providers: [NSItemProvider], kind: UploadKind) -> Bool {
        guard canOperate, historyFile == nil, !providers.isEmpty else { return false }
        // Unlike an open panel, a drag is delivered asynchronously; reserve the
        // modal slot until every provider is decoded, then release before upload.
        presentingDialog = true
        let session = vault
        Task {
            let urls = await UploadDropLoader.urls(from: providers)
            guard urls.count == providers.count else {
                presentingDialog = false
                notice = L10n.tr("无法读取拖入的文件；未开始上传，请通过选择器重试。")
                return
            }
            do { try kind.validate(urls) }
            catch { presentingDialog = false; notice = error.localizedDescription; return }
            presentingDialog = false
            if vault === session { upload(urls) }
        }
        return true
    }
    func download(_ file: StoredFile, version: Int? = nil) {
        guard canOperate, files.contains(where: { $0.id == file.id }) else { return }
        presentingDialog = true
        let panel = NSSavePanel(); panel.nameFieldStringValue = version.map { versionedFilename(file.filename, version: $0) } ?? URL(fileURLWithPath: file.filename).lastPathComponent; panel.prompt = L10n.tr("下载")
        let response = panel.runModal()
        presentingDialog = false
        guard response == .OK, let destination = panel.url else { return }
        run(L10n.tr("准备下载")) { vault, progress in try await vault.download(file.id, to: destination, version: version, progress: progress); return OperationResult(L10n.tr("已下载 %@%@", String(describing: file.filename), String(describing: version.map { " · v\($0)" } ?? ""))) }
    }
    func addFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = L10n.tr("添加同步目录")
        if panel.runModal() == .OK, let url = panel.url { run(L10n.tr("添加目录")) { vault, _ in try await vault.addFolder(url); return OperationResult(L10n.tr("已添加同步目录")) } }
    }
    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.directoryURL = directory; panel.prompt = L10n.tr("选择文件库目录")
        if panel.runModal() == .OK, let url = panel.url {
            directory = url
            passwordStored = KeychainStore.exists(for: url)
        }
    }
    func restoreAll() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = L10n.tr("恢复到此目录")
        if panel.runModal() == .OK, let url = panel.url {
            let alert = NSAlert(); alert.messageText = L10n.tr("恢复全部文件？"); alert.informativeText = L10n.tr("将按文件库中的路径写入所选目录。同名文件在校验通过后会被替换。"); alert.addButton(withTitle: L10n.tr("恢复")); alert.addButton(withTitle: L10n.tr("取消"))
            if alert.runModal() == .alertFirstButtonReturn { run(L10n.tr("恢复文件")) { vault, progress in try await vault.restoreAll(to: url, progress: progress) } }
        }
    }
}
#endif
