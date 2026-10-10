#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This script requires macOS and Xcode command-line tools." >&2
  exit 1
fi
swift build -c release
build_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/TAS.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$build_dir/TAS" "$app/Contents/MacOS/TAS"
cp "$build_dir/tas" "$app/Contents/Helpers/tas"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp .build/checkouts/CryptoSwift/LICENSE "$app/Contents/Resources/CryptoSwift-LICENSE"
for bundle in "$build_dir"/*.bundle; do
  [[ -d "$bundle" ]] && cp -R "$bundle" "$app/Contents/Resources/"
done
swift scripts/icon.swift "$PWD/dist/TAS.iconset"
iconutil -c icns dist/TAS.iconset -o "$app/Contents/Resources/TAS.icns"
mkdir -p "$app/Contents/Frameworks"
xcrun swift-stdlib-tool --copy --scan-executable "$app/Contents/MacOS/TAS" --scan-executable "$app/Contents/Helpers/tas" --platform macosx --destination "$app/Contents/Frameworks"
codesign --force --deep --sign "${TAS_SIGN_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
# Hide build products while testing so bundled resources cannot fall back to the checkout.
mv "$build_dir/TAS_TASCore.bundle" "$build_dir/TAS_TASCore.bundle.hidden"
trap 'mv "$build_dir/TAS_TASCore.bundle.hidden" "$build_dir/TAS_TASCore.bundle"' EXIT
"$app/Contents/Helpers/tas" --self-test
"$app/Contents/MacOS/TAS" --smoke-test
mv "$build_dir/TAS_TASCore.bundle.hidden" "$build_dir/TAS_TASCore.bundle"
trap - EXIT
arch="$(uname -m)"
archive="$PWD/dist/TAS-1.0.0-$arch.zip"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
{
  echo "Architecture: $arch"
  du -sh "$app" "$archive"
  file "$app/Contents/MacOS/TAS" "$app/Contents/Helpers/tas"
  /usr/bin/time -p "$app/Contents/Helpers/tas" --version
} 2>&1 | tee "dist/build-report-$arch.txt"
echo "Built $archive"
