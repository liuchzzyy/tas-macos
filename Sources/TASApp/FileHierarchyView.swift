#if os(macOS)
import SwiftUI
import TASCore

/// Folder rows are a projection only: selecting one resolves to every stored file
/// below its path, and file actions always use stable stored IDs.
struct FileHierarchyView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    let files: [StoredFile]
    let allFiles: [StoredFile]
    let search: String
    @Binding var selectedIDs: Set<String>
    let batchDownload: ([StoredFile], Bool) -> Void
    let batchDelete: ([StoredFile]) -> Void
    let editTags: (StoredFile) -> Void
    @State private var expanded: Set<String> = []
    @State private var projection = LibraryProjection()

    var body: some View {
        let rows = projection.rows
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Label(search.isEmpty ? L10n.tr("按文件夹浏览") : L10n.tr("搜索结果 · 已展开路径"), systemImage: "folder")
                    .font(LibraryStyle.helper).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("全部展开")) {
                    expanded = projection.folderPaths
                }.disabled(!search.isEmpty)
                Button(L10n.tr("全部折叠")) { expanded = []; selectedIDs = []; model.selectedFileID = nil }.disabled(!search.isEmpty)
            }.controlSize(.small)
            Table(rows, selection: Binding<Set<String>>(
                get: { selectedIDs },
                set: { ids in
                    selectedIDs = ids.intersection(Set(rows.map(\.id)))
                    publishSelection()
                }
            )) {
                TableColumn(L10n.tr("名称")) { row in
                    HStack(spacing: 6) {
                        if row.node.isFolder {
                            Button { toggle(row.node.path) } label: {
                                Image(systemName: expanded.contains(row.node.path) || !search.isEmpty ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold)).frame(width: 14, height: 24)
                            }.buttonStyle(.plain).disabled(!search.isEmpty)
                                .accessibilityLabel(L10n.tr("展开或折叠：%@", String(describing: row.node.path)))
                        } else { Color.clear.frame(width: 14, height: 1) }
                        Image(systemName: row.node.isFolder ? "folder.fill" : "doc")
                            .foregroundStyle(TASDesign.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.node.name).fontWeight(row.node.isFolder ? .medium : .regular)
                                .lineLimit(1).truncationMode(.middle)
                            if let file = row.node.file {
                                if !file.tags.isEmpty { Text(file.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                if file.syncPaused { Label(L10n.tr("同步已暂停"), systemImage: "pause.circle").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                    .padding(.leading, CGFloat(min(row.depth, 6)) * 14)
                    .help(row.node.path)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(row.node.path)
                }.width(min: 180, ideal: 300)
                TableColumn(L10n.tr("版本")) { row in
                    if let file = row.node.file { Text(L10n.tr("v%@ · 共 %@", String(describing: file.versionNumber), String(describing: file.versionCount))).monospacedDigit() }
                    else { Text(L10n.tr("文件夹")).foregroundStyle(.secondary) }
                }.width(80)
                TableColumn(L10n.tr("大小")) { row in
                    if let file = row.node.file { Text(bytes(file.originalSize)).monospacedDigit() }
                    else { Text("—").foregroundStyle(.tertiary) }
                }.width(75)
                TableColumn(L10n.tr("更新时间")) { row in
                    if let file = row.node.file { Text(String(file.updatedAt.prefix(16)).replacingOccurrences(of: "T", with: " ")).foregroundStyle(.secondary) }
                }.width(120)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                selectionMenu(ids)
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first, let node = rows.first(where: { $0.id == id })?.node, node.isFolder, search.isEmpty { toggle(node.path) }
            }
            .disabled(!model.canOperate)
            .onChange(of: rows.map(\.id)) { _, _ in clampSelection() }
        }
        .onChange(of: files, initial: true) { _, _ in updateProjection() }
        .onChange(of: expanded) { _, _ in updateProjection() }
        .onChange(of: search.isEmpty) { _, _ in updateProjection() }
    }

    @ViewBuilder
    private func selectionMenu(_ ids: Set<String>) -> some View {
        let folders = LibrarySelection.folderPaths(in: ids)
        let targets = LibrarySelection.targets(ids, allFiles: allFiles)
        if ids.count == 1, let folder = folders.first {
            Button(L10n.tr("展开或折叠")) { toggle(folder) }.disabled(!search.isEmpty)
            Button(L10n.tr("下载文件夹…")) { batchDownload(targets, true) }.disabled(targets.isEmpty)
            Divider()
            Button(targets.first?.deleted == true ? L10n.tr("永久清除文件夹内全部文件…") : L10n.tr("删除文件夹内全部文件…"), role: .destructive) {
                batchDelete(targets)
            }.disabled(targets.isEmpty)
        } else if targets.count == 1, let file = targets.first {
            Button(L10n.tr("下载…")) { model.download(file) }
            Button(file.deleted ? L10n.tr("查看历史并恢复…") : L10n.tr("版本历史…")) { model.showHistory(file) }
            if !file.deleted {
                Button(L10n.tr("编辑标签…")) { editTags(file) }
                Button(L10n.tr("恢复自动同步…")) { model.resumeFileSync(file) }.disabled(!file.syncPaused)
            }
            Divider()
            Button(file.deleted ? L10n.tr("永久清除…") : L10n.tr("删除并保留历史…"), role: .destructive) { model.deleteFile(file, permanently: file.deleted) }
        } else if targets.count > 1 {
            Button(L10n.tr("下载所选…")) { batchDownload(targets, !folders.isEmpty) }
            Divider()
            Button(targets[0].deleted ? L10n.tr("永久清除所选…") : L10n.tr("删除所选并保留历史…"), role: .destructive) { batchDelete(targets) }
        }
    }

    /// Folder rows stay selectable, so a lone file is what drives the single-file tools.
    private func publishSelection() {
        let targets = LibrarySelection.targets(selectedIDs, allFiles: allFiles)
        let filesOnly = selectedIDs.allSatisfy { $0.hasPrefix("file:") }
        let next: StoredFile.ID? = filesOnly && targets.count == 1 ? targets.first?.id : nil
        if model.selectedFileID != next { model.selectedFileID = next }
    }

    private func clampSelection() {
        let clamped = selectedIDs.intersection(Set(projection.rows.map(\.id)))
        if clamped != selectedIDs { selectedIDs = clamped }
        publishSelection()
    }

    private func updateProjection() {
        projection.update(files: files, expanded: expanded, expandAll: !search.isEmpty)
        clampSelection()
    }

    private func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }
}
#endif
