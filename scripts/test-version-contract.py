#!/usr/bin/env python3
"""GUI/CLI release metadata contract, independent of UI implementation."""
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VersionContractTests(unittest.TestCase):
    def test_gui_and_cli_versions_are_independent(self):
        info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], '1.3.3')
        self.assertEqual(info['CFBundleVersion'], '12')
        self.assertEqual(info['TASCLIVersion'], '1.3.1')
        cli = (ROOT / 'Sources/tas/CLI.swift').read_text()
        self.assertIn('tas 1.3.1 (Swift)', cli)
        self.assertNotIn('1.3.3', cli)

    def test_artifacts_follow_gui_version(self):
        for path in ['scripts/build-macos.sh', '.github/workflows/macos.yml']:
            text = (ROOT / path).read_text()
            self.assertIn('TAS-1.3.3-arm64.dmg', text)

    def test_checksum_is_portable_after_download(self):
        build = (ROOT / 'scripts/build-macos.sh').read_text()
        self.assertIn('cd dist && shasum -a 256 TAS-1.3.3-arm64.dmg > TAS-1.3.3-arm64.dmg.sha256', build)

    def test_ci_checksum_verification_uses_artifact_directory(self):
        workflow = (ROOT / '.github/workflows/macos.yml').read_text()
        self.assertIn('(cd dist && shasum -a 256 -c TAS-1.3.3-arm64.dmg.sha256)', workflow)

    def test_installer_uses_signed_cli_declaration(self):
        source = (ROOT / 'Sources/TASApp/UpdateInstaller.swift').read_text()
        self.assertIn('TASCLIVersion', source)
        self.assertIn('matchesBundleDeclaration', source)
        self.assertNotIn('.cli == release.version', source)


if __name__ == '__main__':
    unittest.main()
