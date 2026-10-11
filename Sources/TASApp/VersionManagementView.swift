#if os(macOS)
import SwiftUI
import AppKit
import TASCore

/// Software release versions. File history remains in the file list and its sheet.
struct VersionManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var checking = false
    @State private var installing = false
    @State private var status: String?
    @State private var release: ReleaseUpdate?
    @State private var latestVersion: String?
    @State private var releaseNotes: String?
    @State private var cliVersion: String?
    @State private var cliProbePending = true

    private var preview: Bool {
        #if TAS_UI_PREVIEW
        CommandLine.arguments.contains("--ui-preview") || CommandLine.arguments.contains("--ui-preview-versions")
        #else
        false
        #endif
    }
    private var guiVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }
    private var versions: SoftwareVersions { SoftwareVersions(gui: guiVersion, cliOutput: cliVersion) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("版本管理").font(LibraryStyle.pageTitle).accessibilityAddTraits(.isHeader)
                    Text("查看桌面客户端与随应用提供的命令行版本。")
                        .font(LibraryStyle.body).foregroundStyle(.secondary)
                }
                versionCard(title: "桌面客户端 (GUI)", icon: "macwindow", installed: guiVersion,
                            latest: latestVersion, detail: "TAS.app · 图形界面")
                versionCard(title: "命令行工具 (CLI)", icon: "terminal", installed: versions.cli ?? (cliProbePending ? "检测中…" : "未检测到"),
                            latest: latestVersion, detail: "内置 tas · 随 GUI 一起发布")
                LibrarySurface {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("检查与安装").font(LibraryStyle.sectionTitle)
                            Spacer()
                            Button("检查更新", systemImage: "arrow.clockwise") { Task { await check() } }
                                .disabled(checking || installing || preview)
                        }
                        Divider()
                        if checking { ProgressView("正在查询 GitHub Release…").controlSize(.small) }
                        if installing { ProgressView("正在下载并校验安装包…").controlSize(.small) }
                        if let status { Text(status).font(LibraryStyle.body).foregroundStyle(.secondary) }
                        if let release, !cliProbePending {
                            HStack {
                                Button("更新 GUI 与 CLI 至 \(release.version)…") { Task { await install(release) } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(checking || installing || model.busy || model.historyFile != nil || preview)
                                Link("查看 Release", destination: release.releaseURL)
                            }
                        }
                        if preview { Text("界面预览 · 不连接网络或文件库；版本来自当前预览应用包").font(LibraryStyle.helper).foregroundStyle(.secondary) }
                        else { Text("CLI 是应用包内的命令行程序，与 GUI 一同更新；不单独替换系统 PATH 中的其他 tas。")
                            .font(LibraryStyle.helper).foregroundStyle(.secondary) }
                    }
                }
                if let releaseNotes, !releaseNotes.isEmpty {
                    LibrarySurface {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("最新版本说明").font(LibraryStyle.sectionTitle)
                            Divider()
                            Text(releaseNotes).font(LibraryStyle.body).textSelection(.enabled)
                        }
                    }
                }
                if !preview {
                    Link("在浏览器查看所有 Releases", destination: URL(string: "https://github.com/liuchzzyy/tas-macos/releases")!)
                        .font(LibraryStyle.helper)
                }
            }
            .padding(28)
            .frame(maxWidth: 1050, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(TASDesign.canvas)
        .onAppear {
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

    private func versionCard(title: String, icon: String, installed: String, latest: String?, detail: String) -> some View {
        LibrarySurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(title, systemImage: icon).font(LibraryStyle.sectionTitle)
                    Spacer()
                    if let latest, installed == latest {
                        Label("最新版本", systemImage: "checkmark.circle.fill")
                            .font(LibraryStyle.helper).foregroundStyle(TASDesign.accent)
                    }
                }
                Text(detail).font(LibraryStyle.helper).foregroundStyle(.secondary)
                Divider()
                HStack(spacing: 0) {
                    versionValue("当前版本", installed)
                    Divider().frame(height: 42)
                    versionValue("最新版本", latest ?? "待检查")
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
        checking = true; status = nil; release = nil; latestVersion = nil; releaseNotes = nil
        defer { checking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/liuchzzyy/tas-macos/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("TAS-macOS", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw UpdateInstaller.Failure("GitHub Release 不可用")
            }
            let latest = try ReleaseUpdate(data: data)
            latestVersion = latest.version
            releaseNotes = (try? JSONDecoder().decode(ReleaseNotes.self, from: data))?.body
            release = latest
            updateDecision(for: latest.version)
        } catch { status = "检查更新失败：\(error.localizedDescription)"; release = nil; latestVersion = nil; releaseNotes = nil }
    }
    private func updateDecision(for latest: String) {
        guard let checkedRelease = release, checkedRelease.version == latest else {
            status = "Release 状态已变化，请重新检查更新。"
            return
        }
        if versions.isAhead(of: latest) {
            status = "当前安装的 GUI 或 CLI 高于公开 Release（\(latest)），不会降级。"
            release = nil
        } else if cliProbePending {
            status = "GUI 版本已检查，正在检测内置 CLI。"
        } else if versions.cli == nil || guiVersion == "开发版" {
            status = "无法确定当前 GUI 或内置 CLI 版本；请检查应用包安装是否完整。"
            release = nil
        } else if versions.canInstall(release: latest) {
            status = "发现新版本 \(latest)；更新安装包会同时更新 GUI 与内置 CLI。"
        } else {
            status = "已是最新版本（\(latest)）"
            release = nil
        }
    }
    private struct ReleaseNotes: Decodable { let body: String? }

    private func install(_ release: ReleaseUpdate) async {
        guard !installing, !checking, !preview, !model.busy, model.historyFile == nil,
              !cliProbePending, versions.cli != nil,
              versions.canInstall(release: release.version) else { return }
        let alert = NSAlert()
        alert.messageText = "更新 TAS GUI 与 CLI 到 \(release.version)？"
        alert.informativeText = "下载并校验安装包后退出 TAS，备份旧应用、替换 GUI 和内置 CLI，再重新启动。文件库数据不由更新程序修改。"
        alert.addButton(withTitle: "确认更新")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installing = true; status = nil
        do {
            let currentApp = Bundle.main.bundleURL
            guard currentApp.standardizedFileURL.path == "/Applications/TAS.app" else {
                throw UpdateInstaller.Failure("自动更新仅支持 /Applications/TAS.app；请手动安装 DMG。")
            }
            let helper = currentApp.appendingPathComponent("Contents/Helpers/TASUpdater")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw UpdateInstaller.Failure("当前安装缺少更新组件，请手动安装新版。")
            }
            let prepared = try await Task.detached(priority: .userInitiated) {
                try await UpdateInstaller.prepare(release, helper: helper)
            }.value
            // Preparation suspends this task: a transfer or history sheet may have started meanwhile.
            // Never terminate the app until active work has completed.
            guard !model.busy, model.historyFile == nil, !model.presentingDialog else {
                try? FileManager.default.removeItem(at: prepared.app.deletingLastPathComponent())
                throw UpdateInstaller.Failure("下载期间开始了文件库操作；请待其完成后重新检查更新。")
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
            status = "更新失败：\(error.localizedDescription)"
            installing = false
        }
    }
}
#endif
