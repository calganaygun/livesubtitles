#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
dist_dir="$project_root/dist"
archive_path="$dist_dir/LiveSubtitles.xcarchive"
app_path="$archive_path/Products/Applications/LiveSubtitles.app"
submission_zip="$dist_dir/LiveSubtitles-notarization.zip"
staging_dir="$dist_dir/dmg-root"
notary_profile="${NOTARY_PROFILE:-livesubtitles-notary}"

if [[ ! "${DEVELOPMENT_TEAM:-}" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Set DEVELOPMENT_TEAM to your 10-character Apple Developer Team ID." >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No Developer ID Application certificate with private key was found." >&2
  exit 1
fi

mkdir -p "$dist_dir"
rm -rf "$archive_path" "$submission_zip" "$staging_dir"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcodebuild archive \
  -project "$project_root/LiveSubtitles.xcodeproj" \
  -scheme LiveSubtitles \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$archive_path" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application"

codesign --verify --deep --strict --verbose=2 "$app_path"

signature_details="$(codesign -dvv "$app_path" 2>&1)"
if [[ "$signature_details" != *"Authority=Developer ID Application:"* ]]; then
  echo "Archive is not signed with a Developer ID Application certificate." >&2
  exit 1
fi
if [[ "$signature_details" != *"Timestamp="* ]]; then
  echo "Archive has no secure signing timestamp." >&2
  exit 1
fi
if [[ "$signature_details" != *"runtime"* ]]; then
  echo "Archive is not protected by Hardened Runtime." >&2
  exit 1
fi

entitlements="$(codesign -d --entitlements :- "$app_path" 2>&1)"
if [[ "$entitlements" == *"com.apple.security.get-task-allow"* ]]; then
  echo "Release contains the unsafe get-task-allow entitlement." >&2
  exit 1
fi

ditto -c -k --keepParent "$app_path" "$submission_zip"
xcrun notarytool submit "$submission_zip" \
  --keychain-profile "$notary_profile" \
  --wait

xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
release_zip="$dist_dir/LiveSubtitles-$version.zip"
release_dmg="$dist_dir/LiveSubtitles-$version.dmg"
rm -f "$release_zip" "$release_dmg"

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

xcrun notarytool submit "$release_dmg" \
  --keychain-profile "$notary_profile" \
  --wait

xcrun stapler staple "$release_dmg"
xcrun stapler validate "$release_dmg"
spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$release_dmg"

rm -rf "$staging_dir" "$submission_zip"
echo "Notarized releases:"
echo "  $release_zip"
echo "  $release_dmg"
