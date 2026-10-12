#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TASCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if TAS_UI_PREVIEW
        if UIPreviewRenderer.renderIfRequested() { return }
        #endif
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
        WindowGroup("TAS") {
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
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu(L10n.tr("文件库")) {
                Button(L10n.tr("版本历史…")) { if let file = model.selection { model.showHistory(file) } }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!model.canUseSelection)
                Button(L10n.tr("恢复自动同步…")) { if let file = model.selection { model.resumeFileSync(file) } }.disabled(!model.canResumeSync)
                Divider()
                Button(L10n.tr("删除并保留历史…")) { if let file = model.selection { model.deleteFile(file) } }.disabled(!model.canUploadVersion)
                Button(L10n.tr("永久清除…"), role: .destructive) { if let file = model.selection { model.deleteFile(file, permanently: true) } }.disabled(!model.canUseSelection || model.selection?.deleted != true)
                Divider()
                Button(L10n.tr("锁定文件库")) { model.lock() }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(!model.canOperate || model.historyFile != nil)
                Button(L10n.tr("备份索引")) { model.run(L10n.tr("备份索引")) { vault, _ in try await vault.backupIndex() } }.disabled(!model.canOperate || model.historyFile != nil)
            }
        }
    }
}

func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
#else
import Foundation
@main struct UnsupportedHost { static func main() { fputs("TAS.app requires macOS 26 or later. Use the tas CLI on this platform.\n", stderr) } }
#endif
