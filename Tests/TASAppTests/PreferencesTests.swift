import XCTest
import SwiftUI
@testable import TASApp

final class PreferencesTests: XCTestCase {
    @MainActor func testPreferencesPersistAndRejectInvalidValuesWithoutRecreatingModel() {
        let suite = "TASPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.appearance, .system)
        preferences.language = .english
        preferences.appearance = .dark
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.language, .english)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.appearance.colorScheme, .dark)
        defaults.set("garbage", forKey: AppPreferences.languageKey)
        defaults.set("garbage", forKey: AppPreferences.appearanceKey)
        XCTAssertEqual(AppPreferences(defaults: defaults).appearance, .system)
        XCTAssertEqual(AppPreferences(defaults: defaults).language, .chinese)
    }
    @MainActor func testRememberChoiceDefaultsOffAndPersists() {
        let suite = "TASPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.rememberPassword)
        preferences.rememberPassword = true
        XCTAssertTrue(AppPreferences(defaults: defaults).rememberPassword)
        preferences.rememberPassword = false
        XCTAssertFalse(AppPreferences(defaults: defaults).rememberPassword)
    }
    @MainActor func testAutoCheckUpdatesDefaultsOffAndPersists() {
        let suite = "TASPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.autoCheckUpdates)
        preferences.autoCheckUpdates = true
        XCTAssertTrue(AppPreferences(defaults: defaults).autoCheckUpdates)
        preferences.autoCheckUpdates = false
        XCTAssertFalse(AppPreferences(defaults: defaults).autoCheckUpdates)
    }
    @MainActor func testStartupPreferencesPersistAndCloseDefaultsToQuit() {
        let suite = "TASPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertFalse(prefs.silentLaunch)
        XCTAssertEqual(prefs.closeBehavior, .quit)
        prefs.silentLaunch = true
        prefs.closeBehavior = .menuBar
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.silentLaunch)
        XCTAssertEqual(reloaded.closeBehavior, .menuBar)
        defaults.set("invalid", forKey: AppPreferences.closeBehaviorKey)
        XCTAssertEqual(AppPreferences(defaults: defaults).closeBehavior, .quit)
    }
    @MainActor func testClosePolicyQuitsByDefaultAndRetainsMenuBarWhenSelected() {
        let suite = "TASPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertTrue(StartupSettings.shouldQuitAfterLastWindow(preferences: prefs))
        prefs.closeBehavior = .menuBar
        XCTAssertFalse(StartupSettings.shouldQuitAfterLastWindow(preferences: prefs))
    }
    @MainActor func testNewStartupStringsAreTranslated() {
        XCTAssertEqual(L10n.tr("登录后启动", language: .english), "Launch at Login")
        XCTAssertEqual(L10n.tr("静默启动", language: .english), "Start Silently")
        XCTAssertEqual(L10n.tr("保留在菜单栏", language: .english), "Keep in Menu Bar")
        XCTAssertEqual(L10n.tr("常规", language: .english), "General")
        XCTAssertEqual(L10n.tr("维护", language: .english), "Maintenance")
        XCTAssertEqual(L10n.tr("机器人", language: .english), "Bots")
        XCTAssertEqual(L10n.tr("上传内容…", language: .english), "Upload Items…")
        XCTAssertEqual(L10n.tr("打开 TAS 主窗口", language: .english), "Open TAS Main Window")
    }
    func testExplicitLocalizationPreservesInterpolatedUserContentAndBotIDs() {
        XCTAssertEqual(L10n.tr("文件同步", language: .english), "File Sync")
        XCTAssertEqual(L10n.tr("文件夹同步", language: .english), "Folder Sync")
        XCTAssertEqual(L10n.tr("已选文件：%@", "文件同步/100%原始.txt", language: .english), "Selected file: 文件同步/100%原始.txt")
        XCTAssertEqual(L10n.botName("primary", language: .english), "Primary bot")
        XCTAssertEqual(L10n.botName("primary", language: .chinese), "主机器人")
        XCTAssertEqual(L10n.botName("自定义", language: .english), "自定义")
        XCTAssertEqual(L10n.tr("unknown.key", language: .english), "unknown.key")
    }
    func testCoreProgressIsTranslatedWithoutChangingUserFilenames() {
        XCTAssertEqual(L10n.current("计算校验值 · 报告/原始%图.txt", language: .english), "Calculating checksum · 报告/原始%图.txt")
        XCTAssertEqual(L10n.current("上传 报告/原始%图.txt · 1/3", language: .english), "Uploading 报告/原始%图.txt · 1/3")
        XCTAssertEqual(L10n.current("同步完成，更新 2 个文件", language: .english), "Sync complete, updated 2 files")
        XCTAssertEqual(L10n.current("备份加密索引", language: .english), "Backing up encrypted index")
        XCTAssertEqual(L10n.current("外部来源的未知错误", language: .english), "外部来源的未知错误")
        XCTAssertEqual(L10n.current("此路径有未完成上传，请先继续或清除", language: .english), "An upload is pending at this path. Resume or clear it first.")
        XCTAssertEqual(L10n.current("本地索引已保存，但远端索引备份失败：网络故障。请重试“备份索引”。", language: .english), "Local index saved, but remote index backup failed: 网络故障. Retry Back up index.")
        XCTAssertEqual(L10n.current("计算校验值 · 文件同步/原始.txt", language: .english), "Calculating checksum · 文件同步/原始.txt")
        XCTAssertEqual(L10n.current("计算校验值 · 报告/原始%图.txt", language: .chinese), "计算校验值 · 报告/原始%图.txt")
        XCTAssertEqual(L10n.current("已恢复版本 2，自动同步已暂停", language: .english), "Restored version 2; automatic sync paused")
        XCTAssertEqual(L10n.current("文件不存在", language: .english), "File not found")
        XCTAssertEqual(L10n.current("解锁文件库失败", language: .english), "解锁文件库失败")
        XCTAssertEqual(L10n.current("本地索引已保存，但远端索引备份失败：此路径有未完成上传，请先继续或清除。请重试“备份索引”。", language: .english), "Local index saved, but remote index backup failed: An upload is pending at this path. Resume or clear it first. Retry Back up index.")
    }
    @MainActor func testLockClearsBoundedLocalizedMessageCache() {
        L10n.clearMessages()
        for index in 0..<300 { _ = L10n.tr("已选文件：%@", "私密文件名\(index)") }
        XCTAssertLessThanOrEqual(L10n.cachedMessageCount, 256)
        L10n.clearMessages()
        XCTAssertEqual(L10n.cachedMessageCount, 0)
    }
}
