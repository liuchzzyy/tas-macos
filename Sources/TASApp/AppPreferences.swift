#if os(macOS)
import SwiftUI
import Foundation

enum AppLanguage: String, CaseIterable { case chinese = "zh-Hans", english = "en" }
enum AppAppearance: String, CaseIterable {
    case light, dark, system
    var colorScheme: ColorScheme? { switch self { case .light: return .light; case .dark: return .dark; case .system: return nil } }
}
enum AppCloseBehavior: String, CaseIterable { case quit, menuBar }

@MainActor final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    static let languageKey = "TAS.interfaceLanguage"
    static let appearanceKey = "TAS.interfaceAppearance"
    static let rememberPasswordKey = "TAS.rememberPassword"
    static let silentLaunchKey = "TAS.silentLaunch"
    static let launchAtLoginKey = "TAS.launchAtLogin"
    static let closeBehaviorKey = "TAS.closeBehavior"
    private let defaults: UserDefaults
    @Published var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: Self.languageKey) } }
    @Published var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) } }
    @Published var silentLaunch: Bool { didSet { defaults.set(silentLaunch, forKey: Self.silentLaunchKey) } }
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Self.launchAtLoginKey) } }
    @Published var closeBehavior: AppCloseBehavior { didSet { defaults.set(closeBehavior.rawValue, forKey: Self.closeBehaviorKey) } }
    /// Off by default: storing the vault password in the keychain is opt-in.
    @Published var rememberPassword: Bool { didSet { defaults.set(rememberPassword, forKey: Self.rememberPasswordKey) } }
    init(defaults: UserDefaults = L10n.defaults) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .chinese
        appearance = AppAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        silentLaunch = defaults.bool(forKey: Self.silentLaunchKey)
        launchAtLogin = defaults.bool(forKey: Self.launchAtLoginKey)
        closeBehavior = AppCloseBehavior(rawValue: defaults.string(forKey: Self.closeBehaviorKey) ?? "") ?? .quit
        rememberPassword = defaults.bool(forKey: Self.rememberPasswordKey)
    }
}

/// Explicit bundle selection avoids changing AppleLanguages or recreating views.
/// Pass user data only as arguments; never use filenames, tags or notes as keys.
enum L10n {
    private struct RenderedMessage { let key: String; let arguments: [CVarArg] }
    private static let messageLock = NSLock()
    private static var messages: [String: RenderedMessage] = [:]
    private static var messageOrder: [String] = []
    static var cachedMessageCount: Int {
        messageLock.lock(); defer { messageLock.unlock() }
        return messages.count
    }
    static func clearMessages() {
        messageLock.lock(); defer { messageLock.unlock() }
        messages.removeAll(); messageOrder.removeAll()
    }
    /// Re-render GUI notices and known core progress/results without translating
    /// arbitrary user filenames or external server responses.
    static func current(_ text: String, language: AppLanguage? = nil) -> String {
        let language = language ?? self.language
        messageLock.lock(); let message = messages[text]; messageLock.unlock()
        if let message { return render(message.key, message.arguments, language: language) }
        if language == .chinese { return text }
        if let translated = translateCore(text, language: language) { return translated }
        return text
    }
    private static func translateCore(_ text: String, language: AppLanguage) -> String? {
        if let key = coreExact[text] { return render(key, [], language: language) }
        if let translated = translateCoreWarning(text, language: language) { return translated }
        for (pattern, key) in corePatterns {
            guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.range == NSRange(text.startIndex..., in: text) else { continue }
            let arguments: [CVarArg] = (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) as CVarArg }
            }
            if arguments.count == match.numberOfRanges - 1 { return render(key, arguments, language: language) }
        }
        return nil
    }
    private static func translateCoreWarning(_ text: String, language: AppLanguage) -> String? {
        let prefix = "本地索引已保存，但远端索引备份失败："
        let suffix = "。请重试“备份索引”。"
        if text.hasPrefix(prefix), text.hasSuffix(suffix) {
            let error = String(text.dropFirst(prefix.count).dropLast(suffix.count))
            let detail = current(error, language: language).trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
            return render("核心·本地索引已保存，但远端索引备份失败：%@。请重试“备份索引”。", [detail], language: language)
        }
        return nil
    }
    private static let coreExact: [String: String] = [
        "文件不存在": "核心·文件不存在",
        "此路径有未完成上传，请先继续或清除": "核心·此路径有未完成上传，请先继续或清除",
        "备份加密索引": "核心·备份加密索引", "上传完成": "核心·上传完成", "内容未变化，已跳过": "核心·内容未变化，已跳过",
        "没有完成新的上传": "核心·没有完成新的上传", "已清除待上传任务": "核心·已清除待上传任务",
        "远端加密索引备份完成": "核心·远端加密索引备份完成", "已恢复自动同步": "核心·已恢复自动同步",
        "同步完成，没有文件需要更新": "核心·同步完成，没有文件需要更新", "机器人连接与本地索引检查通过": "核心·机器人连接与本地索引检查通过",
        "备份恢复后的历史索引": "核心·备份恢复后的历史索引"
    ]
    private static let corePatterns: [(NSRegularExpression, String)] = [
        ("^已恢复版本 ([0-9]+)，自动同步已暂停$", "核心·已恢复版本 %@，自动同步已暂停"),
        ("^已删除 (.+)$", "核心·已删除 %@"),
        ("^已永久清除 (.+)$", "核心·已永久清除 %@"),
        ("^计算校验值 · (.+)$", "核心·计算校验值 · %@"), ("^加密文件 · (.+)$", "核心·加密文件 · %@"),
        ("^上传 (.+) · ([0-9]+)/([0-9]+)$", "核心·上传 %@ · %@/%@"),
        ("^上传完成 · (.+)$", "核心·上传完成 · %@"),
        ("^下载 (.+) · ([0-9]+)/([0-9]+)$", "核心·下载 %@ · %@/%@"),
        ("^解密并校验 · (.+)$", "核心·解密并校验 · %@"),
        ("^下载完成 · (.+)$", "核心·下载完成 · %@"),
        ("^同步完成，更新 ([0-9]+) 个文件$", "核心·同步完成，更新 %@ 个文件"),
        ("^已继续完成 ([0-9]+) 个上传$", "核心·已继续完成 %@ 个上传"),
        ("^已检查 ([0-9]+) 个文件$", "核心·已检查 %@ 个文件"),
        ("^已恢复 ([0-9]+) 个文件$", "核心·已恢复 %@ 个文件"),
        ("^检查 (.+)$", "核心·检查 %@")
    ].compactMap { try? (NSRegularExpression(pattern: $0.0), $0.1) }
    static let defaults: UserDefaults = {
        #if TAS_UI_PREVIEW
        // A process-unique domain keeps preview controls away from real preferences.
        let defaults = UserDefaults(suiteName: "TAS.UI.Preview.\(ProcessInfo.processInfo.processIdentifier)")!
        defaults.register(defaults: [
            "TAS.interfaceLanguage": ProcessInfo.processInfo.environment["TAS_PREVIEW_LANGUAGE"] ?? "zh-Hans",
            "TAS.interfaceAppearance": ProcessInfo.processInfo.environment["TAS_PREVIEW_APPEARANCE"] ?? "system"
        ])
        return defaults
        #else
        return .standard
        #endif
    }()
    static var language: AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: "TAS.interfaceLanguage") ?? "") ?? .chinese
    }
    static func tr(_ key: String, _ arguments: CVarArg..., language: AppLanguage? = nil) -> String {
        let value = render(key, arguments, language: language ?? self.language)
        messageLock.lock()
        if messages[value] == nil { messageOrder.append(value) }
        messages[value] = RenderedMessage(key: key, arguments: arguments)
        if messageOrder.count > 256 {
            let stale = messageOrder.removeFirst()
            messages.removeValue(forKey: stale)
        }
        messageLock.unlock()
        return value
    }
    private static let resourceBundle: Bundle = {
        // SwiftPM's generated accessor only checks the app root, whereas our
        // signed macOS packaging copies bundles into Contents/Resources.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("TAS_TASApp.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
    private static func render(_ key: String, _ arguments: [CVarArg], language: AppLanguage) -> String {
        let bundle = resourceBundle.path(forResource: language.rawValue.lowercased(), ofType: "lproj").flatMap(Bundle.init(path:)) ?? resourceBundle
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return arguments.isEmpty ? format : String(format: format, locale: Locale(identifier: language.rawValue), arguments: arguments)
    }
    static func botName(_ id: String, language: AppLanguage? = nil) -> String {
        id == "primary" ? tr("主机器人", language: language) : id
    }
}

struct PreferencesControls: View {
    @ObservedObject private var preferences = AppPreferences.shared
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("简体中文") { preferences.language = .chinese }
                Button("English") { preferences.language = .english }
            } label: {
                Label(preferences.language == .chinese ? "简体中文" : "English", systemImage: "globe")
            }.menuStyle(.borderlessButton).fixedSize()
                .help(L10n.tr("语言")).accessibilityLabel(L10n.tr("语言"))
            Spacer(minLength: 0)
            ForEach(AppAppearance.allCases, id: \.self) { appearance in
                Button { preferences.appearance = appearance } label: {
                    Image(systemName: appearance == .light ? "sun.max" : appearance == .dark ? "moon" : "display")
                        .frame(width: 24, height: 26)
                        .background(preferences.appearance == appearance ? TASDesign.selected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain)
                    .help(title(appearance)).accessibilityLabel(title(appearance))
                    .accessibilityAddTraits(preferences.appearance == appearance ? .isSelected : [])
            }
        }.font(.system(size: 12)).foregroundStyle(.secondary)
    }
    private func title(_ appearance: AppAppearance) -> String {
        switch appearance { case .light: return L10n.tr("浅色"); case .dark: return L10n.tr("深色"); case .system: return L10n.tr("跟随系统") }
    }
}
#endif
