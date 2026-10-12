#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TASCore

struct SyncView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("文件同步")).font(LibraryStyle.pageTitle)
                    Text(L10n.tr("统一上传文件，或持续同步本地文件夹。")).font(LibraryStyle.body).foregroundStyle(.secondary)
                }
                UploadCenterView()
                LibrarySurface(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("文件夹上传 · 一次性")).font(LibraryStyle.sectionTitle)
                        UploadDropZone(kind: .folders)
                    }
                }
                LibrarySurface(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L10n.tr("持续同步")).font(LibraryStyle.sectionTitle)
                            Spacer()
                            Button(L10n.tr("添加同步目录…")) { model.addFolder() }.disabled(!model.canOperate)
                            Button(L10n.tr("立即同步")) { model.run(L10n.tr("同步文件夹")) { vault, progress in try await vault.sync(progress: progress) } }
                                .buttonStyle(.borderedProminent).disabled(!model.canOperate || model.folders.isEmpty)
                        }
                        Divider()
                        if model.folders.isEmpty { Text(L10n.tr("尚未添加同步目录")).font(LibraryStyle.body).foregroundStyle(.secondary) }
                        ForEach(model.folders) { folder in
                            HStack(spacing: 12) {
                                Image(systemName: "folder").foregroundStyle(.tint)
                                Text(folder.path).font(LibraryStyle.body).lineLimit(1).truncationMode(.middle)
                                    .help(folder.path).accessibilityLabel(L10n.tr("同步目录：%@", String(describing: folder.path))).textSelection(.enabled)
                                Spacer()
                                Button(L10n.tr("移除…")) { model.run(L10n.tr("移除同步目录")) { vault, _ in try await vault.removeFolder(folder.id); return OperationResult(L10n.tr("已移除同步目录")) } }.disabled(!model.canOperate)
                            }.padding(.vertical, 7)
                            if folder.id != model.folders.last?.id { Divider() }
                        }
                        DisclosureGroup(L10n.tr("同步选项")) {
                            VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Spacer()
                            Button(L10n.tr("恢复全部文件…")) { model.restoreAll() }.disabled(!model.canOperate)
                                .help(L10n.tr("选择目标目录，恢复文件库中的全部文件"))
                        }
                        Toggle(L10n.tr("应用打开时，每 30 秒检查一次变化"), isOn: $model.autoSync).disabled(!model.canOperate || model.folders.isEmpty)
                        Text(L10n.tr("新增文件按相对路径上传；修改会创建新版本。本地删除不会删除远端文件。路径冲突会停止本轮同步。历史恢复后，该文件的自动同步会暂停，需在文件列表中手动恢复。"))
                            .font(LibraryStyle.helper).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.padding(.top, 8)
                        }
                    }
                }

            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.tasCanvas()
    }
}
#endif
