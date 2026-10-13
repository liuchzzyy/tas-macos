#!/usr/bin/env python3
"""UI wiring regressions; complements native smoke and core behavior tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sources" / "TASApp"


def app_source():
    return "\n".join(path.read_text() for path in sorted(APP.glob("*.swift")))


def section(start, end):
    owners = [path for path in APP.glob("*.swift") if start in path.read_text()]
    if len(owners) != 1:
        raise AssertionError(f"Expected one source owner for {start!r}, got {owners}")
    text = owners[0].read_text().split(start, 1)[1]
    return text.split(end, 1)[0]


class WorkspaceUIContractTests(unittest.TestCase):
    def test_preview_options_and_vault_open_are_compile_time_isolated(self):
        preview = (APP / "UIPreviewRenderer.swift").read_text()
        self.assertTrue(preview.startswith("#if os(macOS) && TAS_UI_PREVIEW"))
        for flag in ["--ui-width", "--ui-height", "--ui-section"]:
            self.assertIn(flag, preview)
        model = section("final class AppModel:", "final class AppDelegate:")
        open_body = model.split("func open(password:", 1)[1].split("func lock()", 1)[0]
        self.assertIn("#if !TAS_UI_PREVIEW", open_body)
        self.assertIn("UUID().uuidString", model)

    def test_settings_uses_compact_surfaces_at_minimum_height(self):
        settings = section("struct SettingsView:", "struct AddBotView:")
        self.assertGreaterEqual(settings.count("LibrarySurface(padding: 16)"), 3)
        self.assertIn('DisclosureGroup(L10n.tr("恢复与校验"))', settings)
        self.assertIn("VStack(alignment: .leading, spacing: 14)", settings)
        self.assertIn("VStack(alignment: .leading, spacing: 6)", settings)

    def test_overview_metrics_have_equal_compact_height_for_wrapped_english(self):
        dashboard = (APP / "DashboardView.swift").read_text()
        self.assertIn(".frame(height: 144, alignment: .topLeading)", dashboard)
        self.assertIn(".lineLimit(2).fixedSize(horizontal: false, vertical: true)", dashboard)

    def test_compact_sync_cards_leave_room_for_bottom_status(self):
        sync = (APP / "SyncView.swift").read_text()
        self.assertIn("LibrarySurface(padding: 16)", sync)
        self.assertIn("LibrarySurface(padding: 16)", (APP / "UploadCenterView.swift").read_text())

    def test_sync_unifies_one_time_upload_and_separates_continuous_sync(self):
        sync = section("struct SyncView:", "struct SettingsView:")
        center = (APP / "UploadCenterView.swift").read_text()
        self.assertIn('Label(L10n.tr("文件（文件夹）上传")', center)
        self.assertIn('UploadDropZone(kind: .filesAndFolders)', center)
        self.assertNotIn('UploadDropZone(kind: .folders)', sync)
        self.assertIn('Text(L10n.tr("文件夹同步"))', sync)
        self.assertLess(sync.index("UploadCenterView()"), sync.index('Text(L10n.tr("文件夹同步"))'))
        self.assertNotIn('frame(height: 164', (APP / "DashboardView.swift").read_text())
        self.assertIn('NSColor(name:', (APP / "TASDesign.swift").read_text())

    def test_pages_and_model_have_explicit_source_ownership(self):
        for file, declaration in {
            "AppModel.swift": "final class AppModel:",
            "RootView.swift": "struct RootView:",
            "UnlockView.swift": "struct UnlockView:",
            "LibraryView.swift": "struct LibraryView:",
            "TransfersView.swift": "struct TransfersView:",
            "SyncView.swift": "struct SyncView:",
            "SettingsView.swift": "struct SettingsView:",
        }.items():
            self.assertTrue((APP / file).exists(), file)
            self.assertIn(declaration, (APP / file).read_text())
            self.assertNotIn(declaration, (APP / "TASApp.swift").read_text())

    def test_settings_reserves_dialog_and_dismisses_only_accepted_submissions(self):
        settings = section("struct SettingsView:", "struct AddBotView:")
        self.assertIn("model.beginSettingsDialog()", settings)
        self.assertIn("model.endSettingsDialog()", settings)
        add = section("struct AddBotView:", "struct EndpointView:")
        endpoint = section("struct EndpointView:", "func bytes(")
        for sheet in [add, endpoint]:
            self.assertIn("if model.submitSettingsDialog(", sheet)
            self.assertIn("model.canSubmitSettingsDialog", sheet)

    def test_password_change_explains_generational_encryption_without_reencrypting_history(self):
        settings = section("struct ChangePasswordView:", "struct AddBotView:")
        summary = section("struct SettingsView:", "struct ChangePasswordView:")
        english = (APP / "Resources/en.lproj/Localizable.strings").read_text()
        chinese = (APP / "Resources/zh-Hans.lproj/Localizable.strings").read_text()
        readme = (ROOT / "README.md").read_text()
        for phrase in ["新上传使用新一代密钥", "已有内容仍使用过去代密钥", "旧密码仍可解密旧版密文，不能撤销"]:
            self.assertIn(phrase, settings)
            self.assertIn(f'"{phrase}" = ', english)
            self.assertIn(f'"{phrase}" = ', chinese)
        self.assertIn("vault.changePassword(old: previous, new: proposed, confirmation: repeated)", settings)
        self.assertIn("if model.submitSettingsDialog(", settings)
        self.assertIn("model.canSubmitSettingsDialog", settings)
        self.assertIn("model.beginSettingsDialog()", summary)
        self.assertIn("model.endSettingsDialog()", summary)
        self.assertIn("新上传使用新一代密钥", readme)
        self.assertIn("已有内容仍使用过去代密钥", readme)
        self.assertIn("旧版密文", readme)
        self.assertNotIn("现有文件、机器人令牌和远端索引继续使用原加密密钥", readme)
        self.assertNotIn("登录密码已更改；已有密文仍使用原加密密钥", settings)

    def test_sidebar_is_compact_with_scrollable_navigation_and_larger_brand(self):
        root = section("struct RootView:", "struct UnlockView:")
        self.assertIn("ScrollView", root, "Navigation must scroll without hiding the footer")
        self.assertIn(".frame(height: 34)", root)
        self.assertIn(".frame(width: 50, height: 50)", root)
        self.assertIn('Text("TAS").font(.system(size: 30, weight: .bold))', root)

    def test_sidebar_sections_and_navigation_have_consistent_left_edge(self):
        root = (APP / "RootView.swift").read_text()
        design = (APP / "TASDesign.swift").read_text()
        self.assertIn('.frame(width: 18, alignment: .center)', root)
        self.assertIn('.padding(.horizontal, 18)', design.split('struct TASSectionLabel:', 1)[1].split('struct TASCard', 1)[0])
        self.assertNotIn('Label(title, systemImage: icon)', root)

    def test_upload_and_sync_headings_use_requested_short_names(self):
        center = (APP / "UploadCenterView.swift").read_text()
        sync = (APP / "SyncView.swift").read_text()
        self.assertIn('Label(L10n.tr("文件（文件夹）上传")', center)
        self.assertIn('Text(L10n.tr("文件夹同步"))', sync)

    def test_library_uses_hierarchy_without_losing_stable_file_selection(self):
        library = section("struct LibraryView:", "struct Metric:")
        self.assertIn("FileHierarchyView(files: filtered", library)
        self.assertNotIn("Table(filtered", library)
        hierarchy = APP / "FileHierarchyView.swift"
        self.assertTrue(hierarchy.exists())
        text = hierarchy.read_text()
        for wiring in ["LibraryProjection()", "projection.rows", "selectedFileID", "expandAll: !search.isEmpty"]:
            self.assertIn(wiring, text)

    def test_upload_entry_points_exist_only_inside_sync(self):
        library = section("struct LibraryView:", "struct Metric:")
        commands = section(".commands {", "struct RootView:")
        dashboard = (APP / "DashboardView.swift").read_text()
        for outside in [library, commands, dashboard, (APP / "FileHierarchyView.swift").read_text()]:
            self.assertNotIn("chooseUpload", outside)
            self.assertNotIn("chooseNewVersion", outside)
            self.assertNotIn(".onDrop", outside)
        sync = section("struct SyncView:", "struct SettingsView:")
        self.assertIn("UploadCenterView()", sync)
        self.assertNotIn("在其他 Mac 上取回文件", sync)
        self.assertIn('Button(L10n.tr("恢复全部文件…"))', sync)
        self.assertNotIn(".onDrop", sync, "Only dedicated zones may accept drops")
        self.assertNotIn("一次性上传文件夹…", sync, "The redundant one-time folder picker must be removed")
        self.assertNotIn("chooseUpload(folders:", app_source())
        self.assertIn("UploadDropZone(kind: .filesAndFolders)", (APP / "UploadCenterView.swift").read_text())
        center = (APP / "UploadCenterView.swift").read_text()
        self.assertIn("上传文件或文件夹", center)
        self.assertNotIn("chooseNewVersion", center)
        self.assertNotIn("DisclosureGroup", center)
        self.assertNotIn("chooseNewVersion", (APP / "VersionHistoryView.swift").read_text())
        model = section("final class AppModel:", "final class AppDelegate:")
        self.assertIn("UploadPlan.collect", model)
        self.assertIn("withTaskCancellationHandler", model)

    def test_every_screen_uses_explicit_live_localization(self):
        for name in ["TASApp.swift", "RootView.swift", "UnlockView.swift", "LibraryView.swift", "TransfersView.swift", "SyncView.swift", "SettingsView.swift", "DashboardView.swift", "FileHierarchyView.swift", "UploadCenterView.swift", "VersionHistoryView.swift", "VersionManagementView.swift"]:
            text = (APP / name).read_text()
            self.assertIn("L10n.tr(", text, name)
            self.assertIn("AppPreferences.shared", text, name)
        self.assertIn("L10n.tr(", (APP / "UpdateInstaller.swift").read_text())

    def test_live_preferences_and_adaptive_surfaces(self):
        text = app_source()
        self.assertGreaterEqual(text.count("PreferencesControls()"), 2)
        self.assertIn("preferences.appearance.colorScheme", text)
        self.assertNotIn(".preferredColorScheme(.light)", text)
        self.assertNotIn(".id(preferences", text)
        self.assertIn("L10n.botName(bot.id)", text)
        self.assertIn("Color(nsColor:", (APP / "TASDesign.swift").read_text())

    def test_language_menu_is_one_level_and_light_canvas_is_distinct(self):
        controls = (APP / "AppPreferences.swift").read_text().split("struct PreferencesControls:", 1)[1]
        self.assertNotIn('Picker(L10n.tr("语言")', controls)
        self.assertIn('Button("简体中文")', controls)
        self.assertIn('Button("English")', controls)
        design = (APP / "TASDesign.swift").read_text()
        self.assertNotIn('underPageBackgroundColor', design)
        self.assertIn('@Environment(\\.colorScheme)', design)
        self.assertIn('dropZone', design)

    def test_cli_latest_version_comes_from_independent_release_metadata(self):
        versions = (APP / "VersionManagementView.swift").read_text()
        self.assertIn('latestCLI', versions)
        self.assertNotIn('以安装包为准', versions)
        self.assertIn('ReleaseCLIVersion', versions)
        self.assertIn('TASCLIVersion', (APP / "ReleaseCLIVersion.swift").read_text() if (APP / "ReleaseCLIVersion.swift").exists() else '')

    def test_startup_and_close_options_are_wired_in_settings(self):
        settings = (APP / "SettingsView.swift").read_text()
        app = (APP / "TASApp.swift").read_text()
        for label in ("开机自启", "静默启动", "关闭行为"):
            self.assertIn(f'L10n.tr("{label}")', settings)
        self.assertIn('StartupSettings.setLaunchAtLogin', settings)
        self.assertIn('preferences.silentLaunch', settings)
        self.assertIn('preferences.closeBehavior', settings)
        self.assertIn('applicationShouldTerminateAfterLastWindowClosed', app)
        self.assertIn('MenuBarExtra', app)
        self.assertIn('openWindow(id: "main")', app)

    def test_settings_has_no_duplicate_software_version_surface(self):
        settings = section("struct SettingsView:", "struct AddBotView:")
        for obsolete in ["软件版本", "openVersionManagement", "CFBundleShortVersionString", "TASGitHash"]:
            self.assertNotIn(obsolete, settings, f"Settings still duplicates software version UI: {obsolete}")
        self.assertIn('case "versions": VersionManagementView()', section('struct RootView:', 'struct UnlockView:'))


if __name__ == "__main__":
    unittest.main()
