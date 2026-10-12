#if os(macOS)
import SwiftUI
import TASCore

struct DashboardView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    let openSection: (String) -> Void

    private var recentFiles: [StoredFile] {
        Array(model.activeFiles.sorted { $0.updatedAt > $1.updatedAt }.prefix(4))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.tr("概览")).font(LibraryStyle.pageTitle).accessibilityAddTraits(.isHeader)
                        Text(L10n.tr("管理加密文件、版本和备份。"))
                            .font(LibraryStyle.body).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 9) {
                    Image(systemName: model.vault == nil ? "eye" : "checkmark.shield.fill")
                        .foregroundStyle(TASDesign.accent)
                    Text(model.vault == nil ? L10n.tr("界面预览 · 未连接文件库") : L10n.tr("本地文件库已解锁"))
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(model.vault == nil ? L10n.tr("不会读取真实文件或运行操作") : L10n.tr("文件在本机加密后上传"))
                        .font(LibraryStyle.helper).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 17).frame(height: 47)
                .background(TASDesign.selected, in: RoundedRectangle(cornerRadius: 11))

                HStack(spacing: 14) {
                    metric(L10n.tr("当前文件"), value: model.statistics.map { "\($0.files)" } ?? "—", detail: L10n.tr("文件库中的有效文件"), icon: "doc.on.doc")
                    metric(L10n.tr("历史版本"), value: model.statistics.map { "\($0.versions)" } ?? "—", detail: L10n.tr("包含已删除文件"), icon: "clock.arrow.circlepath")
                    metric(L10n.tr("待续传"), value: model.vault == nil ? "—" : "\(model.pending.count)", detail: L10n.tr("未完成的上传"), icon: "arrow.up.circle")
                    metric(L10n.tr("占用空间"), value: model.statistics.map { bytes($0.storedBytes) } ?? "—", detail: L10n.tr("去重后加密内容"), icon: "externaldrive")
                }

                HStack(alignment: .top, spacing: 16) {
                    TASCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                sectionHeading(L10n.tr("最近文件"), icon: "doc.text")
                                Spacer()
                                Button(L10n.tr("查看全部"), systemImage: "arrow.right") { openSection("files") }
                                    .buttonStyle(.borderless)
                            }
                            Divider()
                            if recentFiles.isEmpty {
                                emptyState(model.vault == nil ? L10n.tr("预览中，不读取文件列表") : L10n.tr("还没有文件"), icon: "tray")
                            } else {
                                ForEach(recentFiles) { file in
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.text")
                                            .foregroundStyle(TASDesign.accent)
                                            .frame(width: 34, height: 34)
                                            .background(TASDesign.selected, in: RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(file.filename).lineLimit(1).truncationMode(.middle).help(file.filename)
                                            Text(String(file.updatedAt.prefix(16)).replacingOccurrences(of: "T", with: " "))
                                                .font(LibraryStyle.helper).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 4)
                                        Text("v\(file.versionNumber)")
                                            .font(LibraryStyle.helper).foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    .font(LibraryStyle.body)
                                    .accessibilityElement(children: .combine)
                                    if file.id != recentFiles.last?.id { Divider() }
                                }
                            }
                        }
                    }
                    TASCard {
                        VStack(alignment: .leading, spacing: 16) {
                            sectionHeading(L10n.tr("索引备份"), icon: "externaldrive.badge.timemachine")
                            Divider()
                            Text(L10n.tr("在其他设备恢复文件库时，需要先取回文件索引。"))
                                .font(LibraryStyle.body).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(L10n.tr("最近备份")).font(LibraryStyle.helper).foregroundStyle(.secondary)
                                Text(model.vault == nil ? "—" : (model.manifestDate ?? L10n.tr("尚未备份")))
                                    .font(.callout.weight(.semibold)).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(15)
                            .background(TASDesign.canvas, in: RoundedRectangle(cornerRadius: 10))
                            Button(L10n.tr("备份索引"), systemImage: "arrow.up.doc") {
                                model.run(L10n.tr("备份索引")) { vault, _ in try await vault.backupIndex() }
                            }
                            .disabled(!model.canOperate || model.historyFile != nil)
                        }
                    }
                    .frame(width: 290)
                }

            }
            .frame(maxWidth: 1050, alignment: .leading)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .tasCanvas()
    }

    private func sectionHeading(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline).accessibilityAddTraits(.isHeader)
    }

    private func emptyState(_ title: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 25, weight: .light))
            Text(title).font(LibraryStyle.body)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 114)
    }

    private func metric(_ title: String, value: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 17)).foregroundStyle(TASDesign.accent)
                .frame(width: 36, height: 36)
                .background(TASDesign.selected, in: RoundedRectangle(cornerRadius: 9))
            Text(title).font(LibraryStyle.helper).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded))
                .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .frame(height: 164, alignment: .topLeading)
        .background(TASDesign.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(TASDesign.border))
        .accessibilityElement(children: .combine)
    }
}
#endif
