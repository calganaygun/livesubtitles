#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_root/build/LocalRelease"
derived_data="$project_root/build/LocalDerivedData"
dist_dir="$project_root/dist"
staging_dir="$project_root/build/dmg-root"
app_path="$build_dir/LiveSubtitles.app"

mkdir -p "$build_dir" "$dist_dir"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcodebuild build \
  -project "$project_root/LiveSubtitles.xcodeproj" \
  -scheme LiveSubtitles \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$derived_data" \
  CONFIGURATION_BUILD_DIR="$build_dir" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES

codesign --verify --deep --strict --verbose=2 "$app_path"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
release_zip="$dist_dir/LiveSubtitles-$version-local.zip"
release_dmg="$dist_dir/LiveSubtitles-$version-local.dmg"
zip_checksum="$release_zip.sha256"
dmg_checksum="$release_dmg.sha256"

rm -rf "$staging_dir"
rm -f "$release_zip" "$release_dmg" "$zip_checksum" "$dmg_checksum"

ditto -c -k --keepParent "$app_path" "$release_zip"

mkdir -p "$staging_dir"
ditto "$app_path" "$staging_dir/LiveSubtitles.app"
ln -s /Applications "$staging_dir/Applications"
hdiutil create \
  -volname "Live Subtitles" \
  -srcfolder "$staging_dir" \
  -format UDZO \
  -ov \
  "$release_dmg"
hdiutil verify "$release_dmg"

(
  cd "$dist_dir"
  shasum -a 256 "$(basename "$release_zip")" > "$(basename "$zip_checksum")"
  shasum -a 256 "$(basename "$release_dmg")" > "$(basename "$dmg_checksum")"
)

rm -rf "$staging_dir"
echo "Local builds:"
echo "  $app_path"
echo "  $release_zip"
echo "  $zip_checksum"
echo "  $release_dmg"
echo "  $dmg_checksum"
