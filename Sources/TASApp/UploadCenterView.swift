#if os(macOS)
import SwiftUI
import TASCore

struct UploadCenterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var versionTarget: StoredFile.ID?
    @State private var targetSearch = ""
    @State private var showingVersionUpload = false
    private var targets: [StoredFile] {
        model.activeFiles.filter { targetSearch.isEmpty || $0.filename.localizedCaseInsensitiveContains(targetSearch) }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }
    var body: some View {
        LibrarySurface {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label("一次性上传", systemImage: "tray.and.arrow.up").font(LibraryStyle.sectionTitle)
                    Spacer()
                    Button("上传文件…", systemImage: "doc.badge.plus") { model.chooseUpload() }
                        .keyboardShortcut("u")
                    Button("上传文件夹…", systemImage: "folder.badge.plus") { model.chooseUpload(folders: true) }
                        .buttonStyle(.borderedProminent)
                }.disabled(!model.canOperate || model.historyFile != nil)
                Text("也可将文件或文件夹拖到此页。保留文件夹名称和层级，不添加自动同步。")
                    .font(LibraryStyle.body).foregroundStyle(.secondary)
                Text("目录内隐藏项会跳过，空文件夹不保存；符号链接和重名目标会在上传前提示。同名已有文件可确认保存为新版本。")
                    .font(LibraryStyle.helper).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                DisclosureGroup("向已有文件上传新版本", isExpanded: $showingVersionUpload) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("筛选目标文件路径", text: $targetSearch).textFieldStyle(.roundedBorder)
                        HStack {
                            Picker("目标文件", selection: $versionTarget) {
                                Text("请选择目标文件").tag(nil as StoredFile.ID?)
                                ForEach(targets) { file in Text(file.filename).tag(Optional(file.id)) }
                            }.labelsHidden().frame(maxWidth: .infinity)
                            Button("上传新版本…") {
                                if let file = model.activeFiles.first(where: { $0.id == versionTarget }) { model.chooseNewVersion(file) }
                            }.disabled(versionTarget == nil)
                        }
                        Text("保留逻辑路径和全部版本历史；不会改写本地源文件。")
                            .font(LibraryStyle.helper).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
                .disabled(!model.canOperate || model.historyFile != nil || model.activeFiles.isEmpty)
            }
        }
        .onChange(of: targets.map(\.id)) { _, ids in
            if let versionTarget, !ids.contains(versionTarget) { self.versionTarget = nil }
        }
    }
}
#endif
