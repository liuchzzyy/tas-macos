#if os(macOS)
import SwiftUI
import TASCore

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    private var recentFiles: [StoredFile] {
        Array(model.activeFiles.sorted { $0.updatedAt > $1.updatedAt }.prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.vault == nil {
                    Label("界面预览 · 未连接文件库，操作已禁用", systemImage: "eye")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(TASDesign.accent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("概览").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text("你的文件库，一目了然。").foregroundStyle(.secondary)
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("文件库概览").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Label(model.vault == nil ? "未连接文件库" : "本地文件库已解锁", systemImage: model.vault == nil ? "lock" : "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(TASDesign.accent)
                    }
                    Spacer(minLength: 12)
                    Button { model.chooseUpload() } label: {
                        Label("上传文件", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canOperate || model.historyFile != nil)
                }

                HStack(alignment: .top, spacing: 0) {
                    metric("文件", value: model.statistics.map { "\($0.files)" } ?? "—", detail: "当前文件", icon: "doc")
                    metricDivider
                    metric("历史版本", value: model.statistics.map { "\($0.versions)" } ?? "—", detail: "包含已删除文件", icon: "clock.arrow.circlepath")
                    metricDivider
                    metric("待续传", value: model.vault == nil ? "—" : "\(model.pending.count)", detail: "未完成上传", icon: "arrow.up.circle")
                    metricDivider
                    metric("占用空间", value: model.statistics.map { bytes($0.storedBytes) } ?? "—", detail: "去重后加密内容", icon: "externaldrive")
                }
                .padding(.vertical, 18)
                .background(TASDesign.canvas, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(TASDesign.border))

                HStack(alignment: .top, spacing: 18) {
                    TASCard {
                        VStack(alignment: .leading, spacing: 19) {
                            Label("索引备份", systemImage: "externaldrive.badge.timemachine")
                                .font(.headline).accessibilityAddTraits(.isHeader)
                            Text("备份文件索引，以便在其他设备上恢复文件库。")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                            VStack(alignment: .leading, spacing: 7) {
                                Text("最近备份").font(.caption).foregroundStyle(.secondary)
                                Text(model.vault == nil ? "预览中，不读取索引" : (model.manifestDate ?? "尚未备份"))
                                    .font(.callout.weight(.medium))
                                    .textSelection(.enabled)
                            }
                            Button("备份索引", systemImage: "arrow.up.doc") {
                                model.run("备份索引") { vault, _ in try await vault.backupIndex() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!model.canOperate || model.historyFile != nil)
                        }
                    }
                    TASCard {
                        VStack(alignment: .leading, spacing: 17) {
                            Label("最近文件", systemImage: "doc.on.doc")
                                .font(.headline).accessibilityAddTraits(.isHeader)
                            Text("按最近更新时间显示本地索引中的文件。")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                            if recentFiles.isEmpty {
                                Text(model.vault == nil ? "预览中，不读取文件列表。" : "还没有文件，上传后会显示在这里。")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else {
                                ForEach(recentFiles) { file in
                                    HStack(spacing: 10) {
                                        Image(systemName: "doc.text").foregroundStyle(TASDesign.accent)
                                        Text(file.filename).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        Text("v\(file.versionNumber)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(34)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(TASDesign.canvas)
    }

    private var metricDivider: some View {
        Rectangle().fill(TASDesign.border).frame(width: 1, height: 83)
    }

    private func metric(_ title: String, value: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
            Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }
}
#endif
