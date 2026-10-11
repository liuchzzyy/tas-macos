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
    func prepareUploads(_ urls: [URL]) -> [UploadRequest]? {
        var names = Set(files.map(\.filename))
        var requests: [UploadRequest] = []
        for url in urls {
            var name = url.lastPathComponent
            var replace = false
            var message: String?
            while names.contains(name) {
                let alert = NSAlert()
                alert.messageText = "“\(name)”已存在"
                let deleted = files.contains { $0.filename == name && $0.deleted }
                alert.informativeText = deleted ? "此逻辑路径已删除，历史仍保留。请先取消上传并从“已删除”的版本历史恢复，或使用其他逻辑路径。" : "保存为新版本会保留该逻辑路径的全部历史，不会覆盖已有版本。也可以使用其他逻辑路径作为独立文件。取消将取消本批上传。"
                alert.addButton(withTitle: "保存为新版本").isEnabled = !deleted
                alert.addButton(withTitle: "使用其他逻辑路径…")
                alert.addButton(withTitle: "取消")
                let note = NSTextField(string: "")
                note.placeholderString = "版本备注（可选）"; note.frame.size = NSSize(width: 360, height: 24)
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
        alert.messageText = "保存到其他逻辑路径"
        alert.informativeText = "请输入相对路径，例如 文档/报告.pdf。不会移动本地源文件。"
        alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: suggested); field.frame.size = NSSize(width: 360, height: 24)
        alert.accessoryView = field
        while alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                alert.informativeText = "路径不能为空，不能是绝对路径，也不能包含空路径段、反斜杠、. 或 ..。"
                continue
            }
            return name
        }
        return nil
    }

    func chooseNewVersion(_ file: StoredFile) {
        guard canOperate, historyFile == nil, let target = files.first(where: { $0.id == file.id }), !target.deleted else { return }
        presentingDialog = true
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "选择新版本"; panel.message = "上传到：\(target.filename)（保留全部历史）"
        guard panel.runModal() == .OK, let url = panel.url else { presentingDialog = false; return }
        let alert = NSAlert(); alert.messageText = "上传新版本到“\(target.filename)”？"
        alert.informativeText = "源文件：\(url.lastPathComponent)\n保留全部已有版本，逻辑路径不变。本地源文件不会被修改。"
        alert.addButton(withTitle: "上传新版本"); alert.addButton(withTitle: "取消")
        let note = NSTextField(string: ""); note.placeholderString = "版本备注（可选）"; note.frame.size = NSSize(width: 360, height: 24)
        alert.accessoryView = note
        let response = alert.runModal(); let message = note.stringValue.isEmpty ? nil : note.stringValue
        presentingDialog = false
        guard response == .alertFirstButtonReturn else { return }
        run("上传新版本") { vault, progress in
            try await vault.upload(url, name: target.filename, replace: true, message: message, progress: progress)
        }
    }

    func showHistory(_ file: StoredFile) {
        guard canOperate, historyFile == nil, let target = files.first(where: { $0.id == file.id }) else { return }
        historyVersions = []; historyFile = target
        // The common refresh path fetches both metadata and the selected history.
        run("载入版本历史") { _, _ in OperationResult("版本历史已更新") }
    }

    func restore(_ file: StoredFile, version: FileVersion, message: String) {
        guard canOperate, version.fileID == file.id, files.contains(where: { $0.id == file.id }), historyVersions.contains(where: { $0.id == version.id }) else { return }
        presentingDialog = true
        let alert = NSAlert(); alert.messageText = "将“\(file.filename)”恢复为 v\(version.number)？"
        alert.informativeText = "将此版本的内容追加为一个新的当前版本，保留全部其他历史。若文件已删除，将恢复到文件列表。\n\n将暂停此文件的自动同步，避免本地内容立即覆盖恢复结果；不会改写或覆盖任何本地源文件。需要时可明确恢复自动同步。"
        alert.addButton(withTitle: "追加版本并恢复"); alert.addButton(withTitle: "取消")
        let response = alert.runModal(); presentingDialog = false
        guard response == .alertFirstButtonReturn else { return }
        run("恢复历史版本") { vault, progress in
            try await vault.restoreVersion(file.id, version: version.number, message: message.isEmpty ? nil : message, progress: progress)
        }
    }

    func resumeFileSync(_ file: StoredFile) {
        guard canOperate, let target = files.first(where: { $0.id == file.id }), !target.deleted, target.syncPaused else { return }
        presentingDialog = true
        let alert = NSAlert(); alert.messageText = "恢复“\(target.filename)”的自动同步？"
        alert.informativeText = "下一次同步可能把本地源文件内容追加为新的当前版本。历史版本仍会保留，本地源文件不会被此操作改写。"
        alert.addButton(withTitle: "恢复自动同步"); alert.addButton(withTitle: "取消")
        let response = alert.runModal(); presentingDialog = false
        guard response == .alertFirstButtonReturn else { return }
        run("恢复自动同步") { vault, _ in try await vault.resumeSync(target.id) }
    }

    func deleteFile(_ file: StoredFile, permanently: Bool = false) {
        guard canOperate, historyFile == nil, let target = files.first(where: { $0.id == file.id }), target.deleted == permanently else { return }
        presentingDialog = true
        let alert = NSAlert(); alert.alertStyle = permanently ? .critical : .warning
        alert.messageText = permanently ? "永久清除“\(target.filename)”及全部历史？" : "删除“\(target.filename)”并保留历史？"
        alert.informativeText = permanently ? "此操作无法撤销，将移除此文件及全部版本记录，并清理不再被引用的远端分块。其他文件引用的内容会保留。" : "文件将移到“已删除”，全部版本仍会保留。可从版本历史恢复；不会删除本地源文件。"
        alert.addButton(withTitle: permanently ? "永久清除" : "删除并保留历史"); alert.addButton(withTitle: "取消")
        let response = alert.runModal(); presentingDialog = false
        guard response == .alertFirstButtonReturn else { return }
        run(permanently ? "永久清除" : "删除文件") { vault, _ in try await vault.delete(target.id, hard: permanently) }
    }
}

struct VersionHistoryView: View {
    let fileID: StoredFile.ID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: FileVersion.ID?
    @State private var note = ""
    private var file: StoredFile? { model.files.first { $0.id == fileID } }
    private var versions: [FileVersion] { model.historyVersions.filter { $0.fileID == fileID }.sorted { $0.number > $1.number } }
    private var selection: FileVersion? { versions.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("版本历史").font(.title2.bold())
                    Text(file?.filename ?? "文件已不可用").foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(!model.canOperate)
            }
            if let file {
                HStack {
                    Text("当前 v\(file.versionNumber) · 共 \(file.versionCount) 个版本").font(.callout)
                    if file.deleted { Label("已删除 · 历史保留", systemImage: "trash").foregroundStyle(.secondary) }
                    Spacer()
                    if file.syncPaused {
                        Label("自动同步已暂停", systemImage: "pause.circle").foregroundStyle(.orange)
                        Button("恢复自动同步…") { model.resumeFileSync(file) }.disabled(!model.canOperate || file.deleted)
                    }
                }
            }
            Text("最新版本在前。下载不会更改当前版本；恢复会追加一个版本并暂停此文件的自动同步。").font(.callout).foregroundStyle(.secondary)
            List(selection: $selected) {
                ForEach(versions) { version in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: version.isCurrent ? "checkmark.circle.fill" : "circle").foregroundStyle(version.isCurrent ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("v\(version.number)").font(.headline)
                                if version.isCurrent { Text("当前版本").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                                Spacer()
                                Text(version.createdAt).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(bytes(version.originalSize)) · 存储 \(bytes(version.storedSize)) · 来源：\(sourceLabel(version.source))").font(.callout)
                            if let sourceID = version.restoredFromVersionID {
                                Text("恢复自 \(versions.first(where: { $0.id == sourceID }).map { "v\($0.number)" } ?? "版本 ID \(sourceID)")").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(version.message.flatMap { $0.isEmpty ? nil : $0 } ?? "无备注").font(.callout).foregroundStyle(.secondary)
                            Text("SHA-256  \(version.hash)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.padding(.vertical, 9).tag(version.id)
                }
            }.listStyle(.inset).disabled(!model.canOperate)
            if versions.isEmpty { Text(model.busy ? "正在载入版本…" : "没有可用的版本历史").foregroundStyle(.secondary) }
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.orange).textSelection(.enabled).lineLimit(3)
            }
            TextField("恢复备注（可选）", text: $note).textFieldStyle(.roundedBorder).disabled(!model.canOperate)
            HStack {
                Text(model.busy ? model.progress.message : "本地源文件不会被恢复操作覆盖。").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("下载所选版本…") { if let file, let selection { model.download(file, version: selection.number) } }.disabled(!model.canOperate || selection == nil || file == nil)
                Button(file?.deleted == true ? "恢复文件为所选版本…" : "恢复为所选版本…") {
                    if let file, let selection { model.restore(file, version: selection, message: note) }
                }.buttonStyle(.borderedProminent).disabled(!model.canOperate || selection == nil || file == nil)
            }
        }.padding(24).frame(width: 780, height: 620)
        .interactiveDismissDisabled(model.busy || model.presentingDialog)
        .onChange(of: model.historyVersions) { _ in
            if !versions.contains(where: { $0.id == selected }) { selected = versions.first?.id }
        }
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "upload": return "手动上传"
        case "sync": return "文件夹同步"
        case "restore": return "历史恢复"
        case "migration": return "旧版迁移"
        default: return source
        }
    }
}
#endif
