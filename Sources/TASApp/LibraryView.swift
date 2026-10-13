#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TASCore

struct LibraryView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    var showDeleted = false
    @State private var search = ""
    @State private var tagging: StoredFile?
    @State private var tag = ""
    @State private var removeTag = false
    @State private var selectedIDs: Set<String> = []
    var filtered: [StoredFile] { model.files.filter { $0.deleted == showDeleted && (search.isEmpty || $0.filename.localizedCaseInsensitiveContains(search) || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) })) } }
    var selection: StoredFile? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return filtered.first { "file:\($0.id)" == id }
    }
    var selectedFiles: [StoredFile] { filtered.filter { selectedIDs.contains("file:\($0.id)") } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(showDeleted ? L10n.tr("已删除") : L10n.tr("所有文件")).font(LibraryStyle.pageTitle)
                    Text(showDeleted ? L10n.tr("选择文件并从版本历史中恢复。") : L10n.tr("按文件夹层级查找、管理和取回文件。"))
                        .font(LibraryStyle.body).foregroundStyle(.secondary)
                }
                Spacer()
            }
            LibrarySurface {
                HStack(spacing: 0) {
                    Metric(title: showDeleted ? L10n.tr("已删除文件") : L10n.tr("文件总数"), value: model.vault == nil ? "—" : "\(model.files.filter { $0.deleted == showDeleted }.count)", icon: showDeleted ? "trash" : "doc.on.doc")
                    Divider().frame(height: 54)
                    Metric(title: L10n.tr("原始大小"), value: model.vault == nil ? "—" : ((try? checkedByteTotal(model.files.filter { $0.deleted == showDeleted }.map(\.originalSize))).map(bytes) ?? L10n.tr("大小无效")), icon: "externaldrive")
                    Divider().frame(height: 54)
                    Metric(title: showDeleted ? L10n.tr("可恢复的历史") : L10n.tr("待续传任务"), value: model.vault == nil ? "—" : (showDeleted ? "\(model.files.filter { $0.deleted }.reduce(0) { $0 + $1.versionCount })" : "\(model.pending.count)"), icon: showDeleted ? "clock.arrow.circlepath" : "arrow.up.circle")
                }
            }
            LibrarySurface {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Text(showDeleted ? L10n.tr("等待恢复") : L10n.tr("文件列表")).font(LibraryStyle.sectionTitle)
                        Spacer(minLength: 16)
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L10n.tr("搜索文件名或标签"), text: $search)
                            .textFieldStyle(.roundedBorder).frame(width: 225)
                    }
                    if selectedFiles.count > 1 {
                        HStack(spacing: 9) {
                            Text(L10n.tr("已选择 %@ 个文件", String(describing: selectedFiles.count)))
                                .font(LibraryStyle.helper).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Button { model.downloadFiles(selectedFiles) } label: { Label(L10n.tr("下载所选…"), systemImage: "arrow.down.to.line") }
                            Button(role: .destructive) { model.deleteFiles(selectedFiles, permanently: showDeleted) } label: {
                                Label(showDeleted ? L10n.tr("永久清除所选…") : L10n.tr("删除所选并保留历史…"), systemImage: "trash")
                            }
                        }.disabled(!model.canOperate || model.historyFile != nil)
                        Divider()
                    } else if let selection {
                        HStack(spacing: 9) {
                            Text(selection.filename).font(LibraryStyle.helper).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(selection.filename)
                                .accessibilityLabel(L10n.tr("已选文件：%@", String(describing: selection.filename)))
                            Spacer(minLength: 12)
                            Button { model.download(selection) } label: { Label(L10n.tr("下载"), systemImage: "arrow.down.to.line") }.disabled(!model.canOperate)
                            Button { model.showHistory(selection) } label: { Label(showDeleted ? L10n.tr("查看并恢复…") : L10n.tr("版本历史"), systemImage: "clock.arrow.circlepath") }.disabled(!model.canUseSelection)
                            Menu {
                                if !showDeleted {
                                    Button(L10n.tr("编辑标签…")) { tagging = selection; model.presentingDialog = true }
                                    if selection.syncPaused { Button(L10n.tr("恢复自动同步…")) { model.resumeFileSync(selection) }.disabled(!model.canResumeSync) }
                                }
                                Button(showDeleted ? L10n.tr("永久清除…") : L10n.tr("删除并保留历史…"), role: .destructive) { model.deleteFile(selection, permanently: selection.deleted) }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                                .help(L10n.tr("更多文件操作")).accessibilityLabel(L10n.tr("更多文件操作")).disabled(!model.canUseSelection)
                        }
                        Divider()
                    } else {
                        Text(model.vault == nil ? L10n.tr("预览模式下不读取文件或提供操作") : (showDeleted ? L10n.tr("选择文件查看历史并恢复") : L10n.tr("选择文件以下载、查看历史或管理标签")))
                            .font(LibraryStyle.helper).foregroundStyle(.secondary)
                    }
                    if model.vault == nil {
                        VStack(spacing: 12) {
                            Image(systemName: "eye").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                            Text(L10n.tr("界面预览 · 未连接文件库")).font(.system(size: 19, weight: .medium))
                            Text(L10n.tr("这里不会显示或读取你的实际文件。"))
                                .font(LibraryStyle.body).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 28)
                    } else if filtered.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: search.isEmpty ? (showDeleted ? "trash" : "tray.and.arrow.up") : "magnifyingglass")
                                .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                            Text(search.isEmpty ? (showDeleted ? L10n.tr("没有已删除的文件") : L10n.tr("还没有文件")) : L10n.tr("没有找到文件"))
                                .font(.system(size: 19, weight: .medium))
                            Text(search.isEmpty ? (showDeleted ? L10n.tr("删除的文件会在这里保留历史，以便恢复。") : L10n.tr("请到“文件同步”上传文件或文件夹。")) : L10n.tr("试试其他文件名或标签。"))
                                .font(LibraryStyle.body).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 40)
                    } else {
                        FileHierarchyView(files: filtered, search: search, selectedIDs: $selectedIDs,
                                          batchDownload: { model.downloadFiles($0) },
                                          batchDelete: { model.deleteFiles($0, permanently: showDeleted) }) { file in
                            tagging = file; model.presentingDialog = true
                        }
                    }
                }
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tasCanvas()
        .onChange(of: filtered.map(\.id)) { _, ids in
            selectedIDs = selectedIDs.intersection(Set(ids.map { "file:\($0)" }))
            if let id = model.selectedFileID, !ids.contains(id) { model.selectedFileID = nil }
        }
        .onDisappear { selectedIDs = []; model.selectedFileID = nil }
        .sheet(item: $tagging, onDismiss: { model.presentingDialog = false }) { target in
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.tr("编辑标签")).font(.title2.bold())
                Text(target.filename).foregroundStyle(.secondary)
                TextField(L10n.tr("标签"), text: $tag).textFieldStyle(.roundedBorder)
                Toggle(L10n.tr("移除此标签"), isOn: $removeTag)
                HStack { Spacer(); Button(L10n.tr("取消")) { tagging = nil }; Button(L10n.tr("保存")) { let value = tag, remove = removeTag; model.presentingDialog = false; model.run(L10n.tr("更新标签")) { vault, _ in try await vault.tag(target.id, value: value, remove: remove) }; tagging = nil }.buttonStyle(.borderedProminent).disabled(tag.isEmpty || model.busy || model.vault == nil) }
            }.padding(28).frame(width: 360)
        }
    }

}

@MainActor extension AppModel {
    func downloadFiles(_ selected: [StoredFile]) {
        guard canOperate, historyFile == nil, selected.count > 1 else { return }
        let ids = Set(selected.map(\.id))
        let targets = files.filter { ids.contains($0.id) && $0.deleted == selected[0].deleted }
        guard targets.count == ids.count else { return }
        presentingDialog = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = L10n.tr("选择下载目录")
        let response = panel.runModal()
        presentingDialog = false
        guard response == .OK, let root = panel.url else { return }
        let destinations = LibrarySelection.downloadNames(targets).map { root.appendingPathComponent($0) }
        guard destinations.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            notice = L10n.tr("下载目录中已有同名文件；未开始下载。请另选目录。")
            return
        }
        run(L10n.tr("下载所选文件")) { vault, progress in
            for (index, target) in targets.enumerated() {
                try Task.checkCancellation()
                progress(TransferProgress(L10n.tr("下载 %@/%@ · %@", String(describing: index + 1), String(describing: targets.count), String(describing: target.filename))))
                try await vault.download(target.id, to: destinations[index], progress: progress)
            }
            return OperationResult(L10n.tr("已下载 %@ 个文件", String(describing: targets.count)))
        }
    }

    func deleteFiles(_ selected: [StoredFile], permanently: Bool) {
        guard canOperate, historyFile == nil, selected.count > 1 else { return }
        let ids = Set(selected.map(\.id))
        let targets = files.filter { ids.contains($0.id) && $0.deleted == permanently }
        guard targets.count == ids.count else { return }
        presentingDialog = true
        let alert = NSAlert()
        alert.alertStyle = permanently ? .critical : .warning
        alert.messageText = permanently
            ? L10n.tr("永久清除 %@ 个文件及全部历史？", String(describing: targets.count))
            : L10n.tr("删除 %@ 个文件并保留历史？", String(describing: targets.count))
        alert.informativeText = permanently
            ? L10n.tr("无法撤销。将逐个清除文件、全部版本记录及不再被引用的远端分块；已清除的文件无法恢复。")
            : L10n.tr("文件将移到“已删除”，全部版本仍会保留；不会删除本地源文件。")
        alert.addButton(withTitle: permanently ? L10n.tr("永久清除所选") : L10n.tr("删除所选"))
        alert.addButton(withTitle: L10n.tr("取消"))
        let response = alert.runModal()
        presentingDialog = false
        guard response == .alertFirstButtonReturn else { return }
        run(permanently ? L10n.tr("永久清除所选") : L10n.tr("删除所选文件")) { vault, progress in
            var warnings: [String] = []
            for (index, target) in targets.enumerated() {
                try Task.checkCancellation()
                progress(TransferProgress(L10n.tr("处理 %@/%@ · %@", String(describing: index + 1), String(describing: targets.count), String(describing: target.filename))))
                let result = try await vault.delete(target.id, hard: permanently)
                if let warning = result.warning { warnings.append(warning) }
            }
            return OperationResult(L10n.tr("已处理 %@ 个文件", String(describing: targets.count)),
                                   warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
        }
    }
}
#endif
