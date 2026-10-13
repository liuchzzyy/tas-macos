#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TASCore

struct TransfersView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.tr("传输任务")).font(LibraryStyle.pageTitle)
                LibrarySurface {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(L10n.tr("待续传")).font(LibraryStyle.sectionTitle)
                            Text("(\(model.pending.count))")
                                .font(LibraryStyle.helper).foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.tr("继续全部上传")) { model.run(L10n.tr("继续上传")) { vault, progress in try await vault.resume(progress: progress) } }
                                .buttonStyle(.borderedProminent).disabled(!model.canOperate || model.pending.isEmpty)
                        }
                        Divider()
                        if model.pending.isEmpty { Text(L10n.tr("没有待续传的任务")).font(LibraryStyle.body).foregroundStyle(.secondary).padding(.vertical, 12) }
                        ForEach(model.pending) { item in
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.up.doc").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.filename).font(LibraryStyle.body).lineLimit(1).truncationMode(.middle).help(item.filename)
                                    Text(L10n.tr("已上传 %@ / %@ 个分块", String(describing: item.uploaded), String(describing: item.total))).font(LibraryStyle.helper).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(L10n.tr("清除…"), role: .destructive) { clear(item) }.disabled(!model.canOperate)
                            }.padding(.vertical, 7)
                            if item.id != model.pending.last?.id { Divider() }
                        }
                    }
                }
                LibrarySurface {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        Text(L10n.tr("本次会话")).font(LibraryStyle.sectionTitle)
                        Divider()
                        Text(L10n.tr("最近 %@ 条", String(model.logs.capacity)))
                            .font(LibraryStyle.helper).foregroundStyle(.secondary)
                        if model.logs.entries.isEmpty { Text(L10n.tr("还没有传输记录")).foregroundStyle(.secondary).font(LibraryStyle.body) }
                        ForEach(model.logs.entries) { log in
                            Text(L10n.current(log.message)).font(LibraryStyle.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            if log.truncated { Text(L10n.tr("此条记录过长，已截断。" )).font(LibraryStyle.helper).foregroundStyle(.secondary) }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.tasCanvas()
    }
    private func clear(_ item: PendingUpload) {
        let alert = NSAlert(); alert.messageText = L10n.tr("清除“%@”的上传任务？", String(describing: item.filename)); alert.informativeText = L10n.tr("已暂存的加密分块将被移除，之后需要重新上传源文件。"); alert.addButton(withTitle: L10n.tr("清除")); alert.addButton(withTitle: L10n.tr("取消"))
        if alert.runModal() == .alertFirstButtonReturn { model.run(L10n.tr("清除任务")) { vault, _ in try await vault.clearPending(item.id) } }
    }
}
#endif
