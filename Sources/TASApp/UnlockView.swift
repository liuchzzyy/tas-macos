#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TASCore

struct UnlockView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var confirmation = ""
    @State private var token = ""
    @State private var chat = ""
    @State private var endpoint = ""
    var body: some View {
        HStack(spacing: 60) {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "shippingbox.fill").font(.system(size: 50)).foregroundStyle(.tint)
                Text(L10n.tr("文件归你。\n随时取回。")).font(.system(size: 36, weight: .semibold)).lineSpacing(6)
                Text("TAS for Mac").font(.title3).foregroundStyle(.secondary)
                Text(L10n.tr("本机加密，上传到 Telegram。")).foregroundStyle(.secondary)
            }.frame(width: 330, alignment: .leading)
            VStack(alignment: .leading, spacing: 16) {
                Text(model.configured ? L10n.tr("解锁文件库") : L10n.tr("创建你的文件库")).font(.title2.bold())
                Text(model.configured ? L10n.tr("输入密码继续。") : L10n.tr("准备 Bot Token 和 Chat ID，并先发送 /start。")).foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
                if !model.configured {
                    SecureField("Bot Token", text: $token)
                    TextField("Chat ID", text: $chat)
                    TextField(L10n.tr("自定义 Bot API 地址（可选）"), text: $endpoint)
                }
                SecureField(L10n.tr("加密密码"), text: $password).onSubmit(submit)
                Toggle(L10n.tr("在 Apple 钥匙串中记住密码"), isOn: Binding(
                    get: { preferences.rememberPassword },
                    set: { model.setRememberPassword($0) }
                ))
                .font(.callout)
                Text(L10n.tr("仅在这台 Mac 的登录钥匙串中保存；其他能使用你 Mac 账户的程序可能访问。关闭后立即移除保存的密码。"))
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                if !model.configured {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(PasswordPolicy.checks(password), id: \.0) { rule in
                            Label(L10n.tr(rule.0), systemImage: rule.1 ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(rule.1 ? Color.green : Color.secondary)
                        }
                    }.font(.caption).accessibilityElement(children: .combine)
                    SecureField(L10n.tr("再次输入密码"), text: $confirmation)
                    if !confirmation.isEmpty {
                        Label(password == confirmation ? L10n.tr("两次密码一致") : L10n.tr("两次密码不一致"), systemImage: password == confirmation ? "checkmark.circle.fill" : "circle")
                            .font(.caption).foregroundStyle(password == confirmation ? Color.green : Color.secondary)
                    }
                }
                Button(action: submit) {
                    HStack { Spacer(); if model.busy { ProgressView().controlSize(.small) }; Text(model.configured ? L10n.tr("解锁") : L10n.tr("创建文件库")); Spacer() }.padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).disabled(model.busy || password.isEmpty || (!model.configured && (!PasswordPolicy.isValid(password) || password != confirmation)))
                Divider()
                PreferencesControls()
                Text(L10n.tr("文件库目录")).font(.caption).foregroundStyle(.secondary)
                HStack { Text(model.directory.path).font(.caption).lineLimit(1).truncationMode(.middle); Spacer(); Button(L10n.tr("更改…")) { model.chooseDirectory() }.disabled(model.busy) }
                Text(L10n.tr("请保管好密码和 config.json。")).font(.caption).foregroundStyle(.tertiary)
            }.textFieldStyle(.roundedBorder).frame(width: 330).padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.autoUnlockIfNeeded() }
        .onChange(of: model.directory) { _, _ in model.autoUnlockIfNeeded() }
    }
    private func submit() {
        if !model.configured && !PasswordPolicy.isValid(password) { model.notice = L10n.tr("密码尚未满足全部要求"); return }
        if !model.configured && password != confirmation { model.notice = L10n.tr("两次输入的密码不一致"); return }
        model.open(password: password, token: model.configured ? nil : token, chat: model.configured ? nil : chat, endpoint: endpoint.isEmpty ? nil : endpoint)
        password = ""; confirmation = ""; token = ""
    }
}
#endif
