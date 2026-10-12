#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TASCore

struct SettingsView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    @State private var addingBot = false
    @State private var editingBot: BotInfo?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("设置")).font(LibraryStyle.pageTitle)
                    Text(L10n.tr("管理文件库、连接与恢复。"))
                        .font(LibraryStyle.body).foregroundStyle(.secondary)
                }
                LibrarySurface(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("文件库")).font(LibraryStyle.sectionTitle)
                        Divider()
                        Text(L10n.tr("存储位置")).font(LibraryStyle.helper).foregroundStyle(.secondary)
                        Text(model.directory.path).font(LibraryStyle.body).textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle).help(model.directory.path)
                        HStack {
                            Text(model.vault == nil ? L10n.tr("界面预览 · 未读取索引") : L10n.tr("最近索引备份：%@", String(describing: model.manifestDate ?? L10n.tr("尚未备份"))))
                                .font(LibraryStyle.helper).foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.tr("备份索引")) { model.run(L10n.tr("备份索引")) { vault, _ in try await vault.backupIndex() } }.disabled(!model.canOperate)
                        }
                    }
                }
                LibrarySurface(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(L10n.tr("Telegram 机器人")).font(LibraryStyle.sectionTitle); Spacer(); Button(L10n.tr("添加…")) { if model.beginSettingsDialog() { addingBot = true } }.disabled(!model.canOperate) }
                        Divider()
                        if model.bots.isEmpty { Text(L10n.tr("尚未添加机器人")).font(LibraryStyle.body).foregroundStyle(.secondary) }
                        ForEach(model.bots) { bot in
                            HStack {
                                Image(systemName: "paperplane.circle.fill").font(.system(size: 20)).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(bot.id == "primary" ? L10n.botName(bot.id) : (bot.username.isEmpty ? bot.id : "@\(bot.username)")).font(LibraryStyle.body.weight(.medium))
                                    Text("\(L10n.botName(bot.id)) · \(bot.chatID)").font(LibraryStyle.helper).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    if let endpoint = bot.endpoint { Text(endpoint).font(LibraryStyle.helper).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                }
                                Spacer()
                                Button(L10n.tr("API 地址…")) { if model.beginSettingsDialog() { editingBot = bot } }.disabled(!model.canOperate)
                                Toggle(L10n.tr("启用"), isOn: Binding(get: { bot.enabled }, set: { enabled in model.run(L10n.tr("更新机器人")) { vault, _ in try await vault.updateBot(bot.id, enabled: enabled); return OperationResult(L10n.tr("机器人已更新")) } })).toggleStyle(.switch).fixedSize().disabled(!model.canOperate)
                            }.padding(.vertical, 7)
                        }
                    }
                }
                LibrarySurface(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.tr("恢复与校验")).font(LibraryStyle.sectionTitle)
                        Text(L10n.tr("以下操作可能需要较长时间；恢复索引会替换当前索引，请先确认备份状态。"))
                            .font(LibraryStyle.helper).foregroundStyle(.secondary)
                        Divider()
                        HStack {
                            Button(L10n.tr("检查连接")) { model.run(L10n.tr("检查连接")) { vault, _ in try await vault.checkBots() } }
                            Button(L10n.tr("完整校验")) { model.run(L10n.tr("完整校验")) { vault, progress in try await vault.verify(deep: true, progress: progress) } }
                            Button(L10n.tr("校验全部历史")) { model.run(L10n.tr("校验全部历史")) { vault, progress in try await vault.verify(deep: true, allVersions: true, progress: progress) } }
                        }.disabled(!model.canOperate)
                        Divider()
                        HStack {
                            Text(L10n.tr("从远端备份替换本机索引")).font(LibraryStyle.body)
                            Spacer()
                            Button(L10n.tr("恢复索引…")) { rebuild() }.disabled(!model.canOperate)
                        }
                    }
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.tasCanvas()
            .sheet(isPresented: $addingBot, onDismiss: { model.endSettingsDialog() }) { AddBotView() }
            .sheet(item: $editingBot, onDismiss: { model.endSettingsDialog() }) { bot in EndpointView(bot: bot) }
    }
    private func rebuild() {
        let alert = NSAlert(); alert.messageText = L10n.tr("从远端恢复索引？"); alert.informativeText = L10n.tr("当前索引会先备份到文件库目录，再由最近一次远端备份替换。尚未进入备份的文件不会显示在恢复后的索引中。"); alert.addButton(withTitle: L10n.tr("备份并恢复")); alert.addButton(withTitle: L10n.tr("取消"))
        if alert.runModal() == .alertFirstButtonReturn { model.run(L10n.tr("恢复索引")) { vault, _ in try await vault.rebuildIndex() } }
    }
}
struct AddBotView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""; @State private var token = ""; @State private var chat = ""; @State private var endpoint = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("添加机器人")).font(.title2.bold()); TextField(L10n.tr("编号，例如 backup"), text: $id); SecureField("Bot Token", text: $token); TextField("Chat ID", text: $chat); TextField(L10n.tr("自定义 Bot API 地址（可选）"), text: $endpoint)
            HStack { Spacer(); Button(L10n.tr("取消")) { dismiss() }; Button(L10n.tr("连接并添加")) { let id = id, token = token, chat = chat, endpoint = endpoint; if model.submitSettingsDialog(L10n.tr("验证机器人"), operation: { vault, _ in try await vault.addBot(id: id, token: token, chatID: chat, endpoint: endpoint.isEmpty ? nil : endpoint); return OperationResult(L10n.tr("机器人已添加")) }) { dismiss() } }.buttonStyle(.borderedProminent).disabled(id.isEmpty || token.isEmpty || chat.isEmpty || !model.canSubmitSettingsDialog) }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 400)
    }
}
struct EndpointView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    let bot: BotInfo
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("Bot API 地址")).font(.title2.bold()); Text(L10n.botName(bot.id)).foregroundStyle(.secondary)
            TextField(L10n.tr("留空使用 https://api.telegram.org"), text: $endpoint).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button(L10n.tr("取消")) { dismiss() }; Button(L10n.tr("保存")) { let value = endpoint; if model.submitSettingsDialog(L10n.tr("更新 API 地址"), operation: { vault, _ in try await vault.updateBot(bot.id, endpoint: value); return OperationResult(L10n.tr("API 地址已更新")) }) { dismiss() } }.buttonStyle(.borderedProminent).disabled(!model.canSubmitSettingsDialog) }
        }.padding(28).frame(width: 430).onAppear { endpoint = bot.endpoint ?? "" }
    }
}
#endif
