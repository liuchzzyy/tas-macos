#if os(macOS)
import SwiftUI
import TASCore

/// Folder rows are a projection only; file actions always use stable stored IDs.
struct FileHierarchyView: View {
    @EnvironmentObject private var model: AppModel
    let files: [StoredFile]
    let search: String
    let editTags: (StoredFile) -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        let roots = LibraryTree.build(files)
        let rows = LibraryTree.visibleRows(roots, expanded: expanded, expandAll: !search.isEmpty)
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Label(search.isEmpty ? "按文件夹浏览" : "搜索结果 · 已展开路径", systemImage: "folder")
                    .font(LibraryStyle.helper).foregroundStyle(.secondary)
                Spacer()
                Button("全部展开") {
                    expanded = Set(LibraryTree.visibleRows(roots, expanded: [], expandAll: true)
                        .filter { $0.node.isFolder }.map { $0.node.path })
                }.disabled(!search.isEmpty)
                Button("全部折叠") { expanded = []; model.selectedFileID = nil }.disabled(!search.isEmpty)
            }.controlSize(.small)
            Table(rows, selection: Binding<String?>(
                get: { model.selectedFileID.map { "file:\($0)" } },
                set: { id in model.selectedFileID = rows.first { $0.id == id }?.node.file?.id }
            )) {
                TableColumn("名称") { row in
                    HStack(spacing: 6) {
                        if row.node.isFolder {
                            Button { toggle(row.node.path) } label: {
                                Image(systemName: expanded.contains(row.node.path) || !search.isEmpty ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold)).frame(width: 14, height: 24)
                            }.buttonStyle(.plain).disabled(!search.isEmpty)
                                .accessibilityLabel("展开或折叠：\(row.node.path)")
                        } else { Color.clear.frame(width: 14, height: 1) }
                        Image(systemName: row.node.isFolder ? "folder.fill" : "doc")
                            .foregroundStyle(TASDesign.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.node.name).fontWeight(row.node.isFolder ? .medium : .regular)
                                .lineLimit(1).truncationMode(.middle)
                            if let file = row.node.file {
                                if !file.tags.isEmpty { Text(file.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                if file.syncPaused { Label("同步已暂停", systemImage: "pause.circle").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                    .padding(.leading, CGFloat(min(row.depth, 6)) * 14)
                    .help(row.node.path)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(row.node.path)
                }.width(min: 180, ideal: 300)
                TableColumn("版本") { row in
                    if let file = row.node.file { Text("v\(file.versionNumber) · 共 \(file.versionCount)").monospacedDigit() }
                    else { Text("文件夹").foregroundStyle(.secondary) }
                }.width(80)
                TableColumn("大小") { row in
                    if let file = row.node.file { Text(bytes(file.originalSize)).monospacedDigit() }
                    else { Text("—").foregroundStyle(.tertiary) }
                }.width(75)
                TableColumn("更新时间") { row in
                    if let file = row.node.file { Text(String(file.updatedAt.prefix(16)).replacingOccurrences(of: "T", with: " ")).foregroundStyle(.secondary) }
                }.width(120)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let id = ids.first, let file = rows.first(where: { $0.id == id })?.node.file {
                    Button("下载…") { model.download(file) }
                    Button(file.deleted ? "查看历史并恢复…" : "版本历史…") { model.showHistory(file) }
                    if !file.deleted {
                        Button("编辑标签…") { editTags(file) }
                        Button("恢复自动同步…") { model.resumeFileSync(file) }.disabled(!file.syncPaused)
                    }
                    Divider()
                    Button(file.deleted ? "永久清除…" : "删除并保留历史…", role: .destructive) { model.deleteFile(file, permanently: file.deleted) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let node = rows.first(where: { $0.id == id })?.node, node.isFolder, search.isEmpty { toggle(node.path) }
            }
            .disabled(!model.canOperate)
            .onChange(of: rows.map(\.id)) { _, ids in
                if let id = model.selectedFileID, !ids.contains("file:\(id)") { model.selectedFileID = nil }
            }
        }
    }

    private func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }
}
#endif
