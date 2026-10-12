#if os(macOS)
import SwiftUI
import AppKit
import TASCore

struct UploadRequest {
    let url: URL
    let name: String
    let replace: Bool
    let message: String?
}

func versionedFilename(_ name: String, version: Int) -> String {
    let url = URL(fileURLWithPath: name)
    let suffix = url.pathExtension
    return "\(url.deletingPathExtension().lastPathComponent)-v\(version)\(suffix.isEmpty ? "" : "." + suffix)"
}

@MainActor extension AppModel {
    // Resolve the entire batch before starting; Cancel never partially uploads a batch.
    func prepareUploads(_ candidates: [UploadCandidate]) -> [UploadRequest]? {
        var names = Set(files.map(\.filename))
        var requests: [UploadRequest] = []
        for candidate in candidates {
            let url = candidate.url
            var name = candidate.name
            var replace = false
            var message: String?
            while names.contains(name) {
                let alert = NSAlert()
                alert.messageText = L10n.tr("“%@”已存在", String(describing: name))
                let deleted = files.contains { $0.filename == name && $0.deleted }
                alert.informativeText = deleted ? L10n.tr("此逻辑路径已删除，历史仍保留。请先取消上传并从“已删除”的版本历史恢复，或使用其他逻辑路径。") : L10n.tr("保存为新版本会保留该逻辑路径的全部历史，不会覆盖已有版本。也可以使用其他逻辑路径作为独立文件。取消将取消本批上传。")
                alert.addButton(withTitle: L10n.tr("保存为新版本")).isEnabled = !deleted
                alert.addButton(withTitle: L10n.tr("使用其他逻辑路径…"))
                alert.addButton(withTitle: L10n.tr("取消"))
                let note = NSTextField(string: "")
                note.placeholderString = L10n.tr("版本备注（可选）"); note.frame.size = NSSize(width: 360, height: 24)
                alert.accessoryView = note
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    replace = true; message = note.stringValue.isEmpty ? nil : note.stringValue
                case .alertSecondButtonReturn:
                    guard let otherName = askLogicalPath(suggested: name) else { return nil }
                    name = otherName
                    continue
                default: return nil
                }
                break
            }
            names.insert(name)
            requests.append(UploadRequest(url: url, name: name, replace: replace, message: message))
        }
        return requests
    }

    private func askLogicalPath(suggested: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.tr("保存到其他逻辑路径")
        alert.informativeText = L10n.tr("请输入相对路径，例如 文档/报告.pdf。不会移动本地源文件。")
        alert.addButton(withTitle: L10n.tr("继续")); alert.addButton(withTitle: L10n.tr("取消"))
        let field = NSTextField(string: suggested); field.frame.size = NSSize(width: 360, height: 24)
        alert.accessoryView = field
        while alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                alert.informativeText = L10n.tr("路径不能为空，不能是绝对路径，也不能包含空路径段、反斜杠、. 或 ..。")
                continue
            }
            return name
        }
        return nil
    }

    func showHistory(_ file: StoredFile) {
        guard canOperate, historyFile == nil, let target = files.first(where: { $0.id == file.id }) else { return }
        historyVersions = []; historyFile = target
        // The common refresh path fetches both metadata and the selected history.
        run(L10n.tr("载入版本历史")) { _, _ in OperationResult(L10n.tr("版本历史已更新")) }
    }

    func restore(_ file: StoredFile, version: FileVersion, message: String) {
        guard canOperate, version.fileID == file.id, files.contains(where: { $0.id == file.id }), historyVersions.contains(where: { $0.id == version.id }) else { return }
        presentingDialog = true
        let alert = NSAlert(); alert.messageText = L10n.tr("将“%@”恢复为 v%@？", String(describing: file.filename), String(describing: version.number))
        alert.informativeText = L10n.tr("将此版本的内容追加为一个新的当前版本，保留全部其他历史。若文件已删除，将恢复到文件列表。\n\n将暂停此文件的自动同步，避免本地内容立即覆盖恢复结果；不会改写或覆盖任何本地源文件。需要时可明确恢复自动同步。")
        alert.addButton(withTitle: L10n.tr("追加版本并恢复")); alert.addButton(withTitle: L10n.tr("取消"))
        let response = alert.runModal(); presentingDialog = false
        guard response == .alertFirstButtonReturn else { return }
        run(L10n.tr("恢复历史版本")) { vault, progress in
            try await vault.restoreVersion(file.id, version: version.number, message: message.isEmpty ? nil : message, progress: progress)
        }
    }

    func resumeFileSync(_ file: StoredFile) {
        guard canOperate, let target = files.first(where: { $0.id == file.id }), !target.deleted, target.syncPaused else { return }
        presentingDialog = true
        let alert = NSAlert(); alert.messageText = L10n.tr("恢复“%@”的自动同步？", String(describing: target.filename))
        alert.informativeText = L10n.tr("下一次同步可能把本地源文件内容追加为新的当前版本。历史版本仍会保留，本地源文件不会被此操作改写。")
        alert.addButton(withTitle: L10n.tr("恢复自动同步")); alert.addButton(withTitle: L10n.tr("取消"))
        let response = alert.runModal(); presentingDialog = false
        guard response == .alertFirstButtonReturn else { return }
        run(L10n.tr("恢复自动同步")) { vault, _ in try await vault.resumeSync(target.id) }
    }

    func deleteFile(_ file: StoredFile, permanently: Bool = false) {
        guard canOperate, historyFile == nil, let target = files.first(where: { $0.id == file.id }), target.deleted == permanently else { return }
        presentingDialog = true
        let alert = NSAlert(); alert.alertStyle = permanently ? .critical : .warning
        alert.messageText = permanently ? L10n.tr("永久清除“%@”及全部历史？", String(describing: target.filename)) : L10n.tr("删除“%@”并保留历史？", String(describing: target.filename))
        alert.informativeText = permanently ? L10n.tr("此操作无法撤销，将移除此文件及全部版本记录，并清理不再被引用的远端分块。其他文件引用的内容会保留。") : L10n.tr("文件将移到“已删除”，全部版本仍会保留。可从版本历史恢复；不会删除本地源文件。")
        alert.addButton(withTitle: permanently ? L10n.tr("永久清除") : L10n.tr("删除并保留历史")); alert.addButton(withTitle: L10n.tr("取消"))
        let response = alert.runModal(); presentingDialog = false
        guard response == .alertFirstButtonReturn else { return }
        run(permanently ? L10n.tr("永久清除") : L10n.tr("删除文件")) { vault, _ in try await vault.delete(target.id, hard: permanently) }
    }
}

struct VersionHistoryView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    let fileID: StoredFile.ID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: FileVersion.ID?
    @State private var note = ""
    private var file: StoredFile? { model.files.first { $0.id == fileID } }
    private var versions: [FileVersion] { model.historyVersions.filter { $0.fileID == fileID }.sorted { $0.number > $1.number } }
    private var selection: FileVersion? { versions.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("版本历史")).font(LibraryStyle.pageTitle)
                    Text(file?.filename ?? L10n.tr("文件已不可用"))
                        .font(LibraryStyle.body).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                        .help(file?.filename ?? L10n.tr("文件已不可用"))
                        .accessibilityLabel(L10n.tr("文件：%@", String(describing: file?.filename ?? L10n.tr("文件已不可用"))))
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(!model.canOperate)
            }
            if let file {
                LibrarySurface {
                    HStack(spacing: 14) {
                        Image(systemName: file.deleted ? "trash" : "clock.arrow.circlepath")
                            .font(.system(size: 21)).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("当前 v%@ · 共 %@ 个版本", String(describing: file.versionNumber), String(describing: file.versionCount)))
                                .font(.system(size: 19, weight: .semibold)).monospacedDigit()
                            Text(file.deleted ? L10n.tr("已删除 · 历史保留，可恢复文件") : L10n.tr("选择版本以下载或恢复"))
                                .font(LibraryStyle.helper).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if file.syncPaused {
                            VStack(alignment: .trailing, spacing: 5) {
                                Label(L10n.tr("自动同步已暂停"), systemImage: "pause.circle").font(LibraryStyle.helper).foregroundStyle(.orange)
                                Button(L10n.tr("恢复自动同步…")) { model.resumeFileSync(file) }.disabled(!model.canOperate || file.deleted)
                            }
                        }
                    }
                }
            }
            HStack {
                Text(L10n.tr("版本时间线")).font(LibraryStyle.sectionTitle)
                Spacer()
                Text(L10n.tr("最新在前")).font(LibraryStyle.helper).foregroundStyle(.secondary)
            }
            List(selection: $selected) {
                ForEach(versions) { version in
                    VersionTimelineRow(version: version, restoredFrom: version.restoredFromVersionID.flatMap { sourceID in
                        versions.first(where: { $0.id == sourceID }).map { "v\($0.number)" } ?? L10n.tr("版本 ID %@", String(describing: sourceID))
                    }, source: sourceLabel(version.source))
                    .tag(version.id)
                }
            }.listStyle(.inset).disabled(!model.canOperate)
                .background(LibraryStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(LibraryStyle.hairline).allowsHitTesting(false) }
            if versions.isEmpty { Text(model.busy ? L10n.tr("正在载入版本…") : L10n.tr("没有可用的版本历史")).foregroundStyle(.secondary) }
            if let notice = model.notice {
                Text(L10n.current(notice)).font(LibraryStyle.body).foregroundStyle(.orange).textSelection(.enabled).lineLimit(3)
            }
            Text(L10n.tr("下载不会更改当前版本；恢复会追加一个新版本并暂停此文件的自动同步。"))
                .font(LibraryStyle.helper).foregroundStyle(.secondary)
            TextField(L10n.tr("恢复备注（可选）"), text: $note).textFieldStyle(.roundedBorder).disabled(!model.canOperate)
            HStack {
                Text(model.busy ? L10n.current(model.progress.message) : L10n.tr("本地源文件不会被恢复操作覆盖。")).font(LibraryStyle.helper).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(L10n.tr("下载所选版本…")) { if let file, let selection { model.download(file, version: selection.number) } }.disabled(!model.canOperate || selection == nil || file == nil)
                Button(file?.deleted == true ? L10n.tr("恢复文件为所选版本…") : L10n.tr("恢复为所选版本…")) {
                    if let file, let selection { model.restore(file, version: selection, message: note) }
                }.buttonStyle(.borderedProminent).disabled(!model.canOperate || selection == nil || file == nil)
            }
        }.padding(24).frame(width: 800, height: 660)
        .tasCanvas()
        .interactiveDismissDisabled(model.busy || model.presentingDialog)
        .onChange(of: model.historyVersions) { _, _ in
            if !versions.contains(where: { $0.id == selected }) { selected = versions.first?.id }
        }
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "upload": return L10n.tr("手动上传")
        case "sync": return L10n.tr("文件夹同步")
        case "restore": return L10n.tr("历史恢复")
        case "migration": return L10n.tr("旧版迁移")
        default: return source
        }
    }
}

private struct VersionTimelineRow: View {
    @ObservedObject private var preferences = AppPreferences.shared
    let version: FileVersion
    let restoredFrom: String?
    let source: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 3) {
                Image(systemName: version.isCurrent ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(version.isCurrent ? Color.accentColor : .secondary)
                Rectangle().fill(LibraryStyle.hairline).frame(width: 1, height: 74)
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("v\(version.number)").font(.system(size: 19, weight: .semibold)).monospacedDigit()
                    if version.isCurrent {
                        Text(L10n.tr("当前版本")).font(LibraryStyle.helper.weight(.semibold)).foregroundStyle(.tint)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.09), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Text(version.createdAt).font(LibraryStyle.helper).foregroundStyle(.secondary)
                        .lineLimit(1).help(version.createdAt)
                }
                Text(L10n.tr("%@ · 存储 %@ · %@", String(describing: bytes(version.originalSize)), String(describing: bytes(version.storedSize)), String(describing: source)))
                    .font(LibraryStyle.body).foregroundStyle(.secondary).lineLimit(1)
                if let restoredFrom {
                    Text(L10n.tr("恢复自 %@", String(describing: restoredFrom))).font(LibraryStyle.helper).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(restoredFrom)
                }
                if let message = version.message, !message.isEmpty {
                    Text(message).font(LibraryStyle.body).lineLimit(2).truncationMode(.tail).help(message)
                }
                Text("SHA-256  \(version.hash)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(version.hash)
            }
        }.padding(.vertical, 11)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.tr("版本 %@%@；%@；原始大小 %@；存储大小 %@；来源 %@；%@；SHA-256 %@", String(describing: version.number), String(describing: version.isCurrent ? L10n.tr("，当前版本") : ""), String(describing: version.createdAt), String(describing: bytes(version.originalSize)), String(describing: bytes(version.storedSize)), String(describing: source), String(describing: version.message ?? L10n.tr("无备注")), String(describing: version.hash)))
    }
}
#endif
