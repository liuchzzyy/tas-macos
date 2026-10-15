#if os(macOS)
import SwiftUI
import AppKit
import TASCore

/// Software release versions. File history remains in the file list and its sheet.
struct VersionManagementView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    @State private var checking = false
    @State private var installing = false
    @State private var status: String?
    @State private var release: ReleaseUpdate?
    @State private var latestVersion: String?
    @State private var latestCLI: String?
    @State private var checkedCLI = false
    @State private var releaseNotes: String?
    @State private var cliVersion: String?
    @State private var cliProbePending = true

    private var preview: Bool {
        #if TAS_UI_PREVIEW
        true
        #else
        false
        #endif
    }
    private var guiVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.tr("开发版")
    }
    private var versions: SoftwareVersions { SoftwareVersions(gui: guiVersion, cliOutput: cliVersion) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("版本管理")).font(LibraryStyle.pageTitle).accessibilityAddTraits(.isHeader)
                    Text(L10n.tr("查看桌面客户端与随应用提供的命令行版本。"))
                        .font(LibraryStyle.body).foregroundStyle(.secondary)
                }
                versionCard(title: L10n.tr("桌面客户端 (GUI)"), icon: "macwindow", installed: guiVersion,
                            latest: latestVersion, detail: L10n.tr("TAS.app · 图形界面"))
                versionCard(title: L10n.tr("命令行工具 (CLI)"), icon: "terminal", installed: versions.cli ?? (cliProbePending ? L10n.tr("检测中…") : L10n.tr("未检测到")),
                            latest: latestCLI, checked: checkedCLI, detail: L10n.tr("内置 tas · 独立版本号，随应用包分发"))
                LibrarySurface {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L10n.tr("检查与安装")).font(LibraryStyle.sectionTitle)
                            Spacer()
                            Button(L10n.tr("检查更新"), systemImage: "arrow.clockwise") { Task { await check() } }
                                .disabled(checking || installing || preview)
                        }
                        Divider()
                        if checking { ProgressView(L10n.tr("正在查询 GitHub Release…")).controlSize(.small) }
                        if installing { ProgressView(L10n.tr("正在下载并校验安装包…")).controlSize(.small) }
                        if let status { Text(L10n.current(status)).font(LibraryStyle.body).foregroundStyle(.secondary) }
                        if checkedCLI && latestCLI == nil {
                            Text(L10n.tr("未能核实最新 CLI 版本，请查看 Release。"))
                                .font(LibraryStyle.helper).foregroundStyle(.secondary)
                        }
                        if let release, !cliProbePending {
                            HStack {
                                Button(L10n.tr("更新 TAS 至 %@…", String(describing: release.version))) { Task { await install(release) } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(checking || installing || model.busy || model.historyFile != nil || preview)
                                Link(L10n.tr("查看 Release"), destination: release.releaseURL)
                            }
                        }
                        if preview { Text(L10n.tr("界面预览 · 不连接网络或文件库；版本来自当前预览应用包")).font(LibraryStyle.helper).foregroundStyle(.secondary) }
                        else { Text(L10n.tr("CLI 随应用包一同更新。"))
                            .font(LibraryStyle.helper).foregroundStyle(.secondary) }
                    }
                }
                if let releaseNotes, !releaseNotes.isEmpty {
                    LibrarySurface {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.tr("最新版本说明")).font(LibraryStyle.sectionTitle)
                            Divider()
                            Text(releaseNotes).font(LibraryStyle.body).textSelection(.enabled)
                        }
                    }
                }
                if !preview {
                    Link(L10n.tr("在浏览器查看所有 Releases"), destination: URL(string: "https://github.com/liuchzzyy/tas-macos/releases")!)
                        .font(LibraryStyle.helper)
                }
            }
            .padding(28)
            .frame(maxWidth: 1050, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .tasCanvas()
        .onAppear {
            guard !preview else { cliProbePending = false; return }
            Task.detached(priority: .utility) {
                let output = EmbeddedCLIVersionProbe.read(from: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tas"))
                await MainActor.run {
                    cliVersion = output
                    cliProbePending = false
                    if let latestVersion, !checking { updateDecision(for: latestVersion) }
                }
            }
        }
    }

    private func versionCard(title: String, icon: String, installed: String, latest: String?, checked: Bool = false, detail: String) -> some View {
        LibrarySurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(title, systemImage: icon).font(LibraryStyle.sectionTitle)
                    Spacer()
                    if let latest, installed == latest {
                        Label(L10n.tr("最新版本"), systemImage: "checkmark.circle.fill")
                            .font(LibraryStyle.helper).foregroundStyle(TASDesign.accent)
                    }
                }
                Text(detail).font(LibraryStyle.helper).foregroundStyle(.secondary)
                Divider()
                HStack(spacing: 0) {
                    versionValue(L10n.tr("当前版本"), installed)
                    Divider().frame(height: 42)
                    versionValue(L10n.tr("最新版本"), latest ?? (checked ? L10n.tr("暂未获取") : L10n.tr("待检查")))
                }
            }
        }
    }
    private func versionValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(LibraryStyle.helper).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func check() async {
        guard !checking, !preview else { return }
        checking = true; status = nil; release = nil; latestVersion = nil; latestCLI = nil; checkedCLI = false; releaseNotes = nil
        defer { checking = false }
        do {
            let latest = try await ReleaseUpdate.fetchLatest()
            latestVersion = latest.version
            // A GUI release tag does not imply a CLI version. Fetch the tagged
            // package declaration independently; show unavailable on failure.
            do { latestCLI = try await ReleaseCLIVersion.fetch(tag: latest.tag, guiVersion: latest.version) }
            catch { latestCLI = nil }
            checkedCLI = true
            release = latest
            updateDecision(for: latest.version)
        } catch { status = L10n.tr("检查更新失败：%@", String(describing: error.localizedDescription)); release = nil; latestVersion = nil; latestCLI = nil; checkedCLI = false; releaseNotes = nil }
    }
    private func updateDecision(for latest: String) {
        guard let checkedRelease = release, checkedRelease.version == latest else {
            status = L10n.tr("Release 状态已变化，请重新检查更新。")
            return
        }
        if versions.isAhead(of: latest) {
            status = L10n.tr("当前安装的 GUI 高于公开 Release（%@），不会降级。", String(describing: latest))
            release = nil
        } else if cliProbePending {
            status = L10n.tr("GUI 版本已检查，正在检测内置 CLI。")
        } else if versions.cli == nil || Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") == nil {
            status = L10n.tr("无法确定当前 GUI 或内置 CLI 版本；请检查应用包安装是否完整。")
            release = nil
        } else if versions.canInstall(release: latest) {
            status = L10n.tr("发现新版本 %@；将安装新版 GUI 和安装包中提供的 CLI。", String(describing: latest))
        } else {
            status = L10n.tr("已是最新版本（%@）", String(describing: latest))
            release = nil
        }
    }
    private struct ReleaseNotes: Decodable { let body: String? }

    private func install(_ release: ReleaseUpdate) async {
        guard !installing, !checking, !preview, !model.busy, model.historyFile == nil,
              !cliProbePending, versions.cli != nil,
              versions.canInstall(release: release.version) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("更新 TAS 到 %@？", String(describing: release.version))
        alert.informativeText = L10n.tr("下载并校验安装包后退出 TAS，备份旧应用、替换 GUI 和内置 CLI，再重新启动。文件库数据不由更新程序修改。")
        alert.addButton(withTitle: L10n.tr("确认更新"))
        alert.addButton(withTitle: L10n.tr("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installing = true; status = nil
        do {
            let currentApp = Bundle.main.bundleURL
            guard currentApp.standardizedFileURL.path == "/Applications/TAS.app" else {
                throw UpdateInstaller.Failure(L10n.tr("自动更新仅支持 /Applications/TAS.app；请手动安装 DMG。"))
            }
            let helper = currentApp.appendingPathComponent("Contents/Helpers/TASUpdater")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw UpdateInstaller.Failure(L10n.tr("当前安装缺少更新组件，请手动安装新版。"))
            }
            let prepared = try await Task.detached(priority: .userInitiated) {
                try await UpdateInstaller.prepare(release, helper: helper)
            }.value
            // Preparation suspends this task: a transfer or history sheet may have started meanwhile.
            // Never terminate the app until active work has completed.
            guard !model.busy, model.historyFile == nil, !model.presentingDialog else {
                try? FileManager.default.removeItem(at: prepared.app.deletingLastPathComponent())
                throw UpdateInstaller.Failure(L10n.tr("下载期间开始了文件库操作；请待其完成后重新检查更新。"))
            }
            let report = UpdateInstaller.resultURL
            try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: report)
            let process = Process()
            process.executableURL = prepared.helper
            process.arguments = [prepared.app.path, currentApp.path, release.version,
                                 "\(ProcessInfo.processInfo.processIdentifier)", report.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            if model.canOperate { model.lock() }
            NSApp.terminate(nil)
        } catch {
            status = L10n.tr("更新失败：%@", String(describing: error.localizedDescription))
            installing = false
        }
    }
}
#endif
