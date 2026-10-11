#!/usr/bin/env python3
"""UI wiring regressions; complements native smoke and core behavior tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sources" / "TASApp"


def section(start, end):
    text = (APP / "TASApp.swift").read_text()
    return text.split(start, 1)[1].split(end, 1)[0]


class WorkspaceUIContractTests(unittest.TestCase):
    def test_sidebar_is_compact_with_scrollable_navigation_and_larger_brand(self):
        root = section("struct RootView:", "struct UnlockView:")
        self.assertIn("ScrollView", root, "Navigation must scroll without hiding the footer")
        self.assertIn(".frame(height: 34)", root)
        self.assertIn(".frame(width: 50, height: 50)", root)
        self.assertIn('Text("TAS").font(.system(size: 30, weight: .bold))', root)

    def test_library_uses_hierarchy_without_losing_stable_file_selection(self):
        library = section("struct LibraryView:", "struct Metric:")
        self.assertIn("FileHierarchyView(files: filtered", library)
        self.assertNotIn("Table(filtered", library)
        hierarchy = APP / "FileHierarchyView.swift"
        self.assertTrue(hierarchy.exists())
        text = hierarchy.read_text()
        for wiring in ["LibraryTree.build", "LibraryTree.visibleRows", "selectedFileID", "expandAll: !search.isEmpty"]:
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
        self.assertIn('Button("恢复全部文件…")', sync)
        self.assertIn(".onDrop", sync)
        center = (APP / "UploadCenterView.swift").read_text()
        self.assertIn("上传文件夹", center)
        self.assertIn("上传文件", center)
        self.assertIn("chooseNewVersion", center)
        model = section("final class AppModel:", "final class AppDelegate:")
        self.assertIn("UploadPlan.collect", model)
        self.assertIn("withTaskCancellationHandler", model)

    def test_settings_has_no_duplicate_software_version_surface(self):
        settings = section("struct SettingsView:", "struct AddBotView:")
        for obsolete in ["软件版本", "openVersionManagement", "CFBundleShortVersionString", "TASGitHash"]:
            self.assertNotIn(obsolete, settings, f"Settings still duplicates software version UI: {obsolete}")
        self.assertIn('case "versions": VersionManagementView()', (APP / "TASApp.swift").read_text())


if __name__ == "__main__":
    unittest.main()
