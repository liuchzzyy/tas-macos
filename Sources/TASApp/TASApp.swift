#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TASCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences.shared
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if TAS_UI_PREVIEW
        if UIPreviewRenderer.renderIfRequested() { return }
        #endif
        NSApp.setActivationPolicy(.regular)
        if !StartupSettings.shouldStartHidden(arguments: CommandLine.arguments, preferences: preferences) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        StartupSettings.shouldQuitAfterLastWindow(preferences: preferences)
    }
}

@main struct TASApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @ObservedObject private var preferences = AppPreferences.shared
    init() {
        if CommandLine.arguments.contains("--smoke-test") {
            do { print(try Diagnostics.selfTest()); exit(0) }
            catch { fputs("Self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup("TAS", id: "main") {
            RootView().environmentObject(model).frame(minWidth: 960, minHeight: 650)
                .tint(TASDesign.accent)
                .onAppear {
                    #if !TAS_UI_PREVIEW
                    let report = UpdateInstaller.resultURL
                    if let result = try? String(contentsOf: report, encoding: .utf8) {
                        model.notice = result
                        try? FileManager.default.removeItem(at: report)
                    }
                    #endif
                }
                .alert("TAS", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) { Button(L10n.tr("知道了")) { model.notice = nil } } message: { Text(L10n.current(model.notice ?? "")) }
        }
        .defaultSize(width: 1120, height: 760)
        .defaultLaunchBehavior(StartupSettings.shouldStartHidden(arguments: CommandLine.arguments, preferences: preferences) ? .suppressed : .presented)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .tint(TASDesign.accent)
                .preferredColorScheme(preferences.appearance.colorScheme)
                .environment(\.locale, Locale(identifier: preferences.language.rawValue))
        }

        MenuBarExtra {
            MenuBarActions(model: model)
        } label: {
            MenuBarStatusLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarStatusLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let icon: String = {
            if model.busy { return "arrow.triangle.2.circlepath" }
            if model.vault == nil { return "lock" }
            return "shippingbox.fill"
        }()
        Image(systemName: icon)
    }
}

struct MenuBarActions: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.vault != nil {
            Text(L10n.tr("文件库已解锁"))
            Text(L10n.tr("%@ 个文件 · %@", String(model.activeFiles.count), bytes(model.statistics?.storedBytes ?? 0)))
            if model.busy {
                Divider()
                Text(L10n.current(model.progress.message))
            }
        } else {
            Text(L10n.tr("文件库未连接或已锁定"))
        }

        Divider()

        Button(L10n.tr("打开 TAS 主窗口")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        if model.vault != nil {
            Divider()

            Button(L10n.tr("立即同步")) {
                model.run(L10n.tr("同步")) { vault, progress in
                    try await vault.sync(progress: progress)
                }
            }
            .disabled(!model.canOperate)

            Button(L10n.tr("上传内容…")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.selectedSection = "sync"
            }
            .disabled(!model.canOperate)

            Button(L10n.tr("备份索引")) {
                model.run(L10n.tr("备份索引")) { vault, _ in
                    try await vault.backupIndex()
                }
            }
            .disabled(!model.canOperate || model.historyFile != nil)

            Button(L10n.tr("锁定文件库")) {
                model.lock()
            }
            .disabled(!model.canOperate || model.historyFile != nil)
        }

        Divider()

        Button(L10n.tr("设置…")) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button(L10n.tr("退出 TAS")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.tr("上传内容…")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.selectedSection = "sync"
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(!model.canOperate)

            Button(L10n.tr("添加同步目录…")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.addFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!model.canOperate)

            Divider()

            Button(L10n.tr("立即同步")) {
                model.run(L10n.tr("同步")) { vault, progress in
                    try await vault.sync(progress: progress)
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canOperate)

            Button(L10n.tr("备份索引")) {
                model.run(L10n.tr("备份索引")) { vault, _ in
                    try await vault.backupIndex()
                }
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!model.canOperate || model.historyFile != nil)

            Button(L10n.tr("恢复全部文件…")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.restoreAll()
            }
            .disabled(!model.canOperate || model.activeFiles.isEmpty)
        }

        CommandMenu(L10n.tr("显示")) {
            Button(L10n.tr("概览")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.selectedSection = "overview"
            }
            .keyboardShortcut("1", modifiers: .command)

            Button(L10n.tr("所有文件")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.selectedSection = "files"
            }
            .keyboardShortcut("2", modifiers: .command)

            Button(L10n.tr("已删除")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.selectedSection = "deleted"
            }
            .keyboardShortcut("3", modifiers: .command)

            Divider()

            Button(L10n.tr("传输任务")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.selectedSection = "transfers"
            }
            .keyboardShortcut("4", modifiers: .command)

            Button(L10n.tr("文件同步")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.selectedSection = "sync"
            }
            .keyboardShortcut("5", modifiers: .command)
        }

        CommandMenu(L10n.tr("文件库")) {
            Button(L10n.tr("锁定文件库")) {
                model.lock()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!model.canOperate || model.historyFile != nil)

            Divider()

            Button(L10n.tr("下载选中文件…")) {
                if let file = model.selection {
                    model.download(file)
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!model.canUseSelection)

            Button(L10n.tr("版本历史…")) {
                if let file = model.selection {
                    model.showHistory(file)
                }
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!model.canUseSelection)

            Button(L10n.tr("恢复自动同步…")) {
                if let file = model.selection {
                    model.resumeFileSync(file)
                }
            }
            .disabled(!model.canResumeSync)

            Divider()

            Button(L10n.tr("删除并保留历史…")) {
                if let file = model.selection {
                    model.deleteFile(file)
                }
            }
            .disabled(!model.canUploadVersion)

            Button(L10n.tr("永久清除…"), role: .destructive) {
                if let file = model.selection {
                    model.deleteFile(file, permanently: true)
                }
            }
            .disabled(!model.canUseSelection || model.selection?.deleted != true)

            Divider()

            Button(L10n.tr("检查连接")) {
                model.run(L10n.tr("检查连接")) { vault, _ in
                    try await vault.checkBots()
                }
            }
            .disabled(!model.canOperate)

            Button(L10n.tr("完整校验")) {
                model.run(L10n.tr("完整校验")) { vault, progress in
                    try await vault.verify(deep: true, progress: progress)
                }
            }
            .disabled(!model.canOperate)
        }

        CommandGroup(replacing: .help) {
            Button(L10n.tr("TAS 帮助与文档")) {
                if let url = URL(string: "https://github.com/liuchzzyy/tas-macos") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button(L10n.tr("在访达中打开文件库目录")) {
                NSWorkspace.shared.open(model.directory)
            }
        }
    }
}

func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
#else
import Foundation
@main struct UnsupportedHost { static func main() { fputs("TAS.app requires macOS 26 or later. Use the tas CLI on this platform.\n", stderr) } }
#endif
