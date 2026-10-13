#if os(macOS)
import SwiftUI
import TASCore

/// Folder rows are a projection only; file actions always use stable stored IDs.
struct FileHierarchyView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    let files: [StoredFile]
    let search: String
    @Binding var selectedIDs: Set<String>
    let batchDownload: ([StoredFile]) -> Void
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
                    selectedIDs = ids.intersection(Set(rows.compactMap { $0.node.file == nil ? nil : $0.id }))
                    let targets = LibrarySelection.resolve(selectedIDs, rows: rows)
                    model.selectedFileID = targets.count == 1 ? targets.first?.id : nil
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
                let targets = LibrarySelection.resolve(ids, rows: rows)
                if targets.count > 1 {
                    Button(L10n.tr("下载所选…")) { batchDownload(targets) }
                    Divider()
                    Button(targets[0].deleted ? L10n.tr("永久清除所选…") : L10n.tr("删除所选并保留历史…"), role: .destructive) { batchDelete(targets) }
                } else if let file = targets.first {
                    Button(L10n.tr("下载…")) { model.download(file) }
                    Button(file.deleted ? L10n.tr("查看历史并恢复…") : L10n.tr("版本历史…")) { model.showHistory(file) }
                    if !file.deleted {
                        Button(L10n.tr("编辑标签…")) { editTags(file) }
                        Button(L10n.tr("恢复自动同步…")) { model.resumeFileSync(file) }.disabled(!file.syncPaused)
                    }
                    Divider()
                    Button(file.deleted ? L10n.tr("永久清除…") : L10n.tr("删除并保留历史…"), role: .destructive) { model.deleteFile(file, permanently: file.deleted) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let node = rows.first(where: { $0.id == id })?.node, node.isFolder, search.isEmpty { toggle(node.path) }
            }
            .disabled(!model.canOperate)
            .onChange(of: rows.map(\.id)) { _, ids in
                selectedIDs = selectedIDs.intersection(Set(ids.filter { $0.hasPrefix("file:") }))
                if let id = model.selectedFileID, !ids.contains("file:\(id)") { model.selectedFileID = nil }
            }
        }
        .onChange(of: files, initial: true) { _, _ in updateProjection() }
        .onChange(of: expanded) { _, _ in updateProjection() }
        .onChange(of: search.isEmpty) { _, _ in updateProjection() }
    }

    private func updateProjection() {
        projection.update(files: files, expanded: expanded, expandAll: !search.isEmpty)
        selectedIDs = selectedIDs.intersection(Set(projection.rows.compactMap { $0.node.file == nil ? nil : $0.id }))
        let targets = LibrarySelection.resolve(selectedIDs, rows: projection.rows)
        model.selectedFileID = targets.count == 1 ? targets.first?.id : nil
    }

    private func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }
}
#endif
