#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This script requires macOS and Xcode command-line tools." >&2
  exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
  echo "This script builds only for Apple Silicon (arm64)." >&2
  exit 1
fi
echo "Compiling release binaries"
/usr/bin/time -p swift build -c release
build_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/TAS.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$build_dir/TASDesktop" "$app/Contents/MacOS/TAS"
cp "$build_dir/tas" "$app/Contents/Helpers/tas"
cp "$build_dir/TASUpdater" "$app/Contents/Helpers/TASUpdater"
# The signed login item launches the main app with a private startup marker.
# No LaunchAgent or user-library plist is written outside this bundle.
login_item="$app/Contents/Library/LoginItems/TASLoginHelper.app"
mkdir -p "$login_item/Contents/MacOS"
swiftc -O scripts/login-helper.swift -o "$login_item/Contents/MacOS/TASLoginHelper"
cp Resources/LoginHelperInfo.plist "$login_item/Contents/Info.plist"
strip -x "$login_item/Contents/MacOS/TASLoginHelper"
strip -x "$app/Contents/MacOS/TAS" "$app/Contents/Helpers/tas" "$app/Contents/Helpers/TASUpdater"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Embed the source revision in the signed app instead of relying on .git at runtime.
source_hash="$(git rev-parse --short=7 HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then source_hash="${source_hash}-dirty"; fi
/usr/libexec/PlistBuddy -c "Add :TASGitHash string $source_hash" "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp .build/checkouts/CryptoSwift/LICENSE "$app/Contents/Resources/CryptoSwift-LICENSE"
for bundle in "$build_dir"/*.bundle; do
  [[ -d "$bundle" ]] && cp -R "$bundle" "$app/Contents/Resources/"
done
echo "Generating application icon"
/usr/bin/time -p swift scripts/icon.swift "$PWD/dist/TAS.iconset"
iconutil -c icns dist/TAS.iconset -o "$app/Contents/Resources/TAS.icns"
rm -rf dist/TAS.iconset
mkdir -p "$app/Contents/Frameworks"
echo "Copying Swift compatibility libraries"
xcrun swift-stdlib-tool --copy --scan-executable "$app/Contents/MacOS/TAS" --scan-executable "$app/Contents/Helpers/tas" --scan-executable "$app/Contents/Helpers/TASUpdater" --platform macosx --destination "$app/Contents/Frameworks"
echo "Signing login item and application"
codesign --force --sign "${TAS_SIGN_IDENTITY:--}" "$login_item"
codesign --force --deep --sign "${TAS_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$login_item"
codesign --verify --deep --strict "$app"
# Hide build products while testing so bundled resources cannot fall back to the checkout.
mv "$build_dir/TAS_TASCore.bundle" "$build_dir/TAS_TASCore.bundle.hidden"
trap 'mv "$build_dir/TAS_TASCore.bundle.hidden" "$build_dir/TAS_TASCore.bundle"' EXIT
echo "Testing installed resources"
python3 scripts/check-process.py "$app/Contents/Helpers/tas" --self-test
echo "Testing application startup"
python3 scripts/check-process.py "$app/Contents/MacOS/TAS" --smoke-test
mv "$build_dir/TAS_TASCore.bundle.hidden" "$build_dir/TAS_TASCore.bundle"
trap - EXIT
archive="$PWD/dist/TAS-1.3.5-arm64.dmg"
rm -f "$archive"
hdiutil create -volname TAS -srcfolder "$app" -ov -format UDZO "$archive"
hdiutil verify "$archive"
(cd dist && shasum -a 256 TAS-1.3.5-arm64.dmg > TAS-1.3.5-arm64.dmg.sha256)
{
  echo "Architecture: arm64"
  du -sh "$app" "$archive"
  file "$app/Contents/MacOS/TAS" "$app/Contents/Helpers/tas"
  /usr/bin/time -p "$app/Contents/Helpers/tas" --version
} 2>&1 | tee "dist/build-report-arm64.txt"
echo "Built $archive"
