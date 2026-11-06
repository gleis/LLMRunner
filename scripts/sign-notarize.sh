#!/usr/bin/env bash
set -euo pipefail
APP="${1:?Pass the verified app bundle path}"
: "${DEVELOPER_ID_APPLICATION:?Set the Developer ID Application signing identity}"
: "${NOTARYTOOL_PROFILE:?Set an existing notarytool keychain profile}"
[[ -d "$APP/Contents" ]] || { echo "Not an app bundle: $APP" >&2; exit 1; }
DMG="${APP%.app}.dmg"
while IFS= read -r binary; do
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$binary"
done < <(find "$APP/Contents" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \))
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP"
codesign --verify --deep --strict "$APP"
hdiutil create -volname "$(basename "${APP%.app}")" -srcfolder "$APP" -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"
printf 'Verified notarized distribution: %s\n' "$DMG"
