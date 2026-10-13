#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TASCore

struct RootView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    @State private var section: String? = "overview"
    init() {
        #if TAS_UI_PREVIEW
        _section = State(initialValue: (try? UIPreviewOptions(arguments: CommandLine.arguments))?.section ?? "overview")
        #endif
    }
    // Compile only into the isolated UI-preview binary. Release builds never
    // bypass the vault unlock screen or expose a preview launch option.
    private var isolatedUIPreview: Bool {
        #if TAS_UI_PREVIEW
        true
        #else
        false
        #endif
    }
    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var body: some View {
        Group {
            if model.vault == nil && !isolatedUIPreview { UnlockView() }
            else {
                #if TAS_UI_PREVIEW
                if CommandLine.arguments.contains("--ui-render") {
                    HStack(spacing: 0) {
                        workspaceSidebar.frame(width: 230)
                        Divider()
                        workspaceDetail
                    }
                } else {
                    NavigationSplitView { workspaceSidebar } detail: { workspaceDetail }
                }
                #else
                NavigationSplitView { workspaceSidebar } detail: { workspaceDetail }
                #endif
            }
        }
        .preferredColorScheme(preferences.appearance.colorScheme)
        .environment(\.locale, Locale(identifier: preferences.language.rawValue))
        .sheet(item: $model.historyFile, onDismiss: { model.historyVersions = [] }) { file in
            VersionHistoryView(fileID: file.id).environmentObject(model)
        }
        .onChange(of: section) { model.selectedFileID = nil }
        .onReceive(timer) { _ in if model.autoSync && model.canOperate && model.historyFile == nil { model.run(L10n.tr("自动同步")) { vault, progress in try await vault.sync(progress: progress) } } }
    }

    private var workspaceSidebar: some View {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox.fill")
                                 .font(.system(size: 24, weight: .semibold))
                                 .foregroundStyle(.white)
                                 .frame(width: 42, height: 42)
                                 .background(TASDesign.accent, in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                 Text("TAS").font(.system(size: 24, weight: .bold))
                                 Text(L10n.tr("加密文件库")).font(.caption2).foregroundStyle(.tertiary)
                             }
                         }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 14)
                         ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            TASSectionLabel(title: L10n.tr("工作台")).padding(.top, 2)
                            sidebarItem(L10n.tr("概览"), icon: "square.grid.2x2", id: "overview")
                            TASSectionLabel(title: L10n.tr("文件管理")).padding(.top, 8)
                            sidebarItem(L10n.tr("所有文件"), icon: "folder", id: "files")
                            sidebarItem(L10n.tr("已删除"), icon: "trash", id: "deleted")
                            TASSectionLabel(title: L10n.tr("工作流程")).padding(.top, 8)
                            sidebarItem(L10n.tr("传输任务"), icon: "arrow.up.arrow.down", id: "transfers")
                            sidebarItem(L10n.tr("文件同步"), icon: "arrow.triangle.2.circlepath", id: "sync")
                            TASSectionLabel(title: L10n.tr("应用")).padding(.top, 8)
                            sidebarItem(L10n.tr("版本管理"), icon: "arrow.down.app", id: "versions")
                            sidebarItem(L10n.tr("设置"), icon: "slider.horizontal.3", id: "settings")
                        }.padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        }.scrollIndicators(.hidden)
                        Spacer(minLength: 8)
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                 Text(model.vault == nil ? L10n.tr("未连接") : L10n.tr("已解锁"))
                                     .font(.caption2.weight(.semibold)).foregroundStyle(.primary)
                                 Text(model.vault == nil ? "" : L10n.tr("%@ 个文件", String(describing: model.activeFiles.count)))
                                     .font(.caption2).foregroundStyle(.tertiary)
                             }.lineLimit(1)
                            Spacer(minLength: 0)
                            Button { model.lock() } label: {
                                Image(systemName: model.vault == nil ? "lock" : "lock.open.fill")
                                     .font(.system(size: 13, weight: .medium))
                                     .foregroundStyle(TASDesign.accent)
                                     .frame(width: 30, height: 30)
                                     .background(TASDesign.selected, in: RoundedRectangle(cornerRadius: 8))
                             }
                            .buttonStyle(.plain)
                            .disabled(!model.canOperate || model.historyFile != nil)
                            .help(model.vault == nil ? L10n.tr("未连接文件库") : L10n.tr("锁定文件库"))
                            .accessibilityLabel(model.vault == nil ? L10n.tr("文件库未连接") : L10n.tr("锁定文件库"))
                        }
                        .padding(10)
                        .tasCard(cornerRadius: 11)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        PreferencesControls()
                            .padding(.horizontal, 15).padding(.top, 4).padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(TASDesign.sidebar)
                    .navigationSplitViewColumnWidth(min: 215, ideal: 230, max: 255)
    }

    private var workspaceDetail: some View {
                    VStack(spacing: 0) {
                        Group {
                            switch section {
                            case "overview": DashboardView(openSection: { section = $0 })
                            case "versions": VersionManagementView()
                            case "transfers": TransfersView()
                            case "sync": SyncView()
                            case "settings": SettingsView()
                            case "deleted": LibraryView(showDeleted: true).id("deleted")
                            default: LibraryView().id("files")
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        HStack(spacing: 10) {
                            if model.busy { ProgressView().controlSize(.small) }
                            else { Image(systemName: model.vault == nil ? "eye" : "checkmark.circle").foregroundStyle(.secondary) }
                            Text(model.vault == nil && isolatedUIPreview ? L10n.tr("界面预览 · 未连接文件库") : L10n.current(model.progress.message)).font(.caption).lineLimit(1)
                            Spacer()
                            if model.busy {
                                if let fraction = model.progress.fraction { ProgressView(value: fraction).frame(minWidth: 80, maxWidth: 150) }
                                Button(L10n.tr("取消")) { model.cancel() }.controlSize(.small)
                            }
                        }.padding(.horizontal, 18).frame(height: 36)
                    }.tasCanvas()
    }

    private func sidebarItem(_ title: String, icon: String, id: String) -> some View {
        let selected = section == id
        return Button { section = id } label: {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(selected ? TASDesign.accent : .clear)
                    .frame(width: 3, height: 22)
                    .padding(.leading, 5)
                Image(systemName: icon)
                    .frame(width: 18, alignment: .center)
                    .padding(.leading, 10)
                Text(title)
                    .padding(.leading, 6)
                Spacer(minLength: 0)
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? TASDesign.accent : Color.primary)
            .frame(height: 34)
            .background(selected ? TASDesign.surface : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? TASDesign.border : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
