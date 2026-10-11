#if os(macOS)
import SwiftUI
import TASCore

/// Entry point for file-scoped version history. All mutations remain in TASCore.
struct VersionManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var selectedFileID: StoredFile.ID?

    private var files: [StoredFile] {
        model.files.filter { file in
            search.isEmpty || file.filename.localizedCaseInsensitiveContains(search)
                || file.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }
    private var selection: StoredFile? { model.files.first { $0.id == selectedFileID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("版本管理").font(LibraryStyle.pageTitle).accessibilityAddTraits(.isHeader)
                    Text("按文件查看历史版本；下载旧版不会更改当前文件，恢复会追加新版本。")
                        .font(LibraryStyle.body).foregroundStyle(.secondary)
                }
                LibrarySurface {
                    HStack(spacing: 0) {
                        Metric(title: "文件", value: model.vault == nil ? "—" : "\(model.activeFiles.count)", icon: "doc")
                        Divider().frame(height: 54)
                        Metric(title: "保留版本", value: model.statistics.map { "\($0.versions)" } ?? "—", icon: "clock.arrow.circlepath")
                        Divider().frame(height: 54)
                        Metric(title: "已删除", value: model.statistics.map { "\($0.deletedFiles)" } ?? "—", icon: "trash")
                    }
                }
                LibrarySurface {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(spacing: 12) {
                            Text("选择文件").font(LibraryStyle.sectionTitle)
                            Spacer(minLength: 12)
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("搜索文件名或标签", text: $search)
                                .textFieldStyle(.roundedBorder).frame(width: 225)
                                .disabled(model.vault == nil)
                        }
                        Divider()
                        if model.vault == nil {
                            Label("界面预览 · 未连接文件库，不读取实际文件与版本", systemImage: "eye")
                                .font(LibraryStyle.body).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 110)
                        } else if files.isEmpty {
                            Text(search.isEmpty ? "尚无文件版本" : "没有匹配的文件")
                                .font(LibraryStyle.body).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 110)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(files) { file in
                                    Button { selectedFileID = file.id } label: {
                                        HStack(spacing: 13) {
                                            Image(systemName: file.deleted ? "trash" : "doc.text")
                                                .foregroundStyle(TASDesign.accent)
                                                .frame(width: 23)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(file.filename).font(LibraryStyle.body.weight(.medium))
                                                    .lineLimit(1).truncationMode(.middle)
                                                    .help(file.filename)
                                                Text(file.deleted ? "已删除 · 历史保留" : "当前 v\(file.versionNumber)")
                                                    .font(LibraryStyle.helper).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 8)
                                            Text("共 \(file.versionCount) 版")
                                                .font(LibraryStyle.helper).foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(selectedFileID == file.id ? TASDesign.sidebar : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 9))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(file.filename)，共 \(file.versionCount) 个版本，\(file.deleted ? "已删除" : "当前 v\(file.versionNumber)")")
                                    if file.id != files.last?.id { Divider() }
                                }
                            }
                        }
                    }
                }
                if let selection {
                    LibrarySurface {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(selection.filename).font(.headline)
                                    .lineLimit(1).truncationMode(.middle).help(selection.filename)
                                Text(selection.deleted ? "已删除文件：可在历史中选择一个版本恢复" : "当前 v\(selection.versionNumber) · 共 \(selection.versionCount) 个版本")
                                    .font(LibraryStyle.helper).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("查看版本历史…", systemImage: "clock.arrow.circlepath") { model.showHistory(selection) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.canOperate || model.historyFile != nil)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1050, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(TASDesign.canvas)
        .onChange(of: files.map(\.id)) { _, ids in
            if let selectedFileID, !ids.contains(selectedFileID) { self.selectedFileID = nil }
        }
    }
}
#endif
