#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_ROOT="$PROJECT_ROOT/ios"
BUILD_ROOT="$PROJECT_ROOT/.local/ios"
ACTION="${1:-help}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/ios.sh verify | test-large | build | device | archive | export
  verify   Check Swift sources, upload mocks, origin policy and project metadata (macOS CLI tools).
  test-large  Run synthetic 1 GiB streaming and multipart tests; no network or OSS.
  build    Build unsigned Debug and Release for iOS Simulator (full Xcode required).
  device   Build with automatic Personal Team signing for your connected iPhone.
  archive  Create a signed archive for App Store Connect; no upload.
  export   Export an existing archive as an App Store IPA; no upload.

archive requires environment variables:
  YEARLY_TEAM_ID, YEARLY_BUNDLE_ID, YEARLY_SITE_URL,
  YEARLY_PRIVACY_URL, YEARLY_SUPPORT_URL
Optional: YEARLY_VERSION (default 1.0), YEARLY_BUILD_NUMBER (default 1).
export requires YEARLY_TEAM_ID and the archive created above.
Use Xcode Organizer to validate the archive and upload after reviewing it.
device requires YEARLY_TEAM_ID and YEARLY_DEVICE_ID; YEARLY_BUNDLE_ID defaults to family.yearly.app.
Personal installation does not require archive/export, App Store Connect or paid membership.
USAGE
}

verify() {
  mkdir -p "$BUILD_ROOT"
  plutil -lint "$IOS_ROOT/Yearly/Info.plist" "$IOS_ROOT/Yearly/PrivacyInfo.xcprivacy" "$IOS_ROOT/Yearly.xcodeproj/project.pbxproj"
  python3 "$IOS_ROOT/scripts/verify-project.py"
  python3 -m unittest discover -s "$IOS_ROOT/Tests" -p 'test_*.py'
  swiftc -frontend -parse "$IOS_ROOT"/Yearly/*.swift
  swiftc "$IOS_ROOT/Yearly/SiteOrigin.swift" "$IOS_ROOT/Tests/main.swift" -o "$BUILD_ROOT/policy-tests"
  "$BUILD_ROOT/policy-tests"
  swiftc -typecheck "$IOS_ROOT/Yearly/UploadCore.swift" "$IOS_ROOT/Yearly/SiteOrigin.swift" \
    "$IOS_ROOT/Yearly/UploadAPI.swift" "$IOS_ROOT/Yearly/OriginalMetadata.swift" \
    "$IOS_ROOT/Yearly/PhotoOriginals.swift" "$IOS_ROOT/Yearly/UploadQueue.swift"
  swiftc -O "$IOS_ROOT/Yearly/UploadCore.swift" "$IOS_ROOT/Yearly/OriginalMetadata.swift" \
    "$IOS_ROOT/Tests/UploadTests.swift" -o "$BUILD_ROOT/upload-tests"
  "$BUILD_ROOT/upload-tests"
  swiftc "$IOS_ROOT/Yearly/UploadCore.swift" "$IOS_ROOT/Yearly/SiteOrigin.swift" \
    "$IOS_ROOT/Yearly/UploadAPI.swift" "$IOS_ROOT/Tests/UploadAPITests.swift" -o "$BUILD_ROOT/upload-api-tests"
  "$BUILD_ROOT/upload-api-tests"
}

require_xcode() {
  if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo '需要完整 Xcode 和 iOS SDK。安装后设置 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer 再运行。' >&2
    exit 1
  fi
}

case "$ACTION" in
  verify) verify ;;
  test-large)
    verify
    /usr/bin/time -l "$BUILD_ROOT/upload-tests" --large
    ;;
  device)
    require_xcode
    : "${YEARLY_TEAM_ID:?Set your Personal Team ID from Xcode}"
    : "${YEARLY_DEVICE_ID:?Set your connected iPhone identifier from Xcode Devices}"
    xcodebuild -project "$IOS_ROOT/Yearly.xcodeproj" -scheme Yearly -configuration Debug \
      -destination "id=$YEARLY_DEVICE_ID" -derivedDataPath "$BUILD_ROOT/Device" \
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
      "DEVELOPMENT_TEAM=$YEARLY_TEAM_ID" "PRODUCT_BUNDLE_IDENTIFIER=${YEARLY_BUNDLE_ID:-family.yearly.app}" build
    echo "Built: $BUILD_ROOT/Device/Build/Products/Debug-iphoneos/Yearly.app"
    echo 'Install/run using Xcode Run, or xcrun devicectl device install app --device "$YEARLY_DEVICE_ID" <app-path>.'
    ;;
  build)
    require_xcode
    verify
    for configuration in Debug Release; do
      xcodebuild -project "$IOS_ROOT/Yearly.xcodeproj" -scheme Yearly \
        -configuration "$configuration" -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$BUILD_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build
    done
    ;;
  archive)
    : "${YEARLY_TEAM_ID:?Set your Apple Team ID}"
    : "${YEARLY_BUNDLE_ID:?Set your registered Bundle ID}"
    : "${YEARLY_SITE_URL:?Set your production HTTPS site}"
    : "${YEARLY_PRIVACY_URL:?Set your public privacy policy URL}"
    : "${YEARLY_SUPPORT_URL:?Set your public support URL}"
    python3 "$IOS_ROOT/scripts/validate-release.py"
    require_xcode
    verify
    # Separate archives by version/build; never silently replace an archive.
    ARCHIVE="$BUILD_ROOT/Yearly-${YEARLY_VERSION:-1.0}-${YEARLY_BUILD_NUMBER:-1}.xcarchive"
    if [[ -e "$ARCHIVE" ]]; then echo "Archive already exists: $ARCHIVE; increment YEARLY_BUILD_NUMBER." >&2; exit 1; fi
    xcodebuild -project "$IOS_ROOT/Yearly.xcodeproj" -scheme Yearly -configuration Release \
      -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
      -derivedDataPath "$BUILD_ROOT/DerivedData" -allowProvisioningUpdates \
      "DEVELOPMENT_TEAM=$YEARLY_TEAM_ID" "PRODUCT_BUNDLE_IDENTIFIER=$YEARLY_BUNDLE_ID" \
      "MARKETING_VERSION=${YEARLY_VERSION:-1.0}" "CURRENT_PROJECT_VERSION=${YEARLY_BUILD_NUMBER:-1}" \
      "YEARLY_SITE_URL=$YEARLY_SITE_URL" "YEARLY_PRIVACY_URL=$YEARLY_PRIVACY_URL" \
      "YEARLY_SUPPORT_URL=$YEARLY_SUPPORT_URL" archive
    echo "Archive created: $ARCHIVE"
    ;;
  export)
    : "${YEARLY_TEAM_ID:?Set your Apple Team ID}"
    require_xcode
    ARCHIVE="$BUILD_ROOT/Yearly-${YEARLY_VERSION:-1.0}-${YEARLY_BUILD_NUMBER:-1}.xcarchive"
    if [[ ! -d "$ARCHIVE" ]]; then echo 'Run archive first with the same version/build.' >&2; exit 1; fi
    EXPORT="$BUILD_ROOT/Export-${YEARLY_VERSION:-1.0}-${YEARLY_BUILD_NUMBER:-1}"
    if [[ -e "$EXPORT" ]]; then echo "Export already exists: $EXPORT" >&2; exit 1; fi
    mkdir -p "$BUILD_ROOT"
    python3 - "$BUILD_ROOT/ExportOptions.plist" <<'PY'
import os, plistlib, sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({'method': 'app-store-connect', 'destination': 'export',
                  'signingStyle': 'automatic', 'teamID': os.environ['YEARLY_TEAM_ID'],
                  'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True}, file)
PY
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
      -exportOptionsPlist "$BUILD_ROOT/ExportOptions.plist" -exportPath "$EXPORT" -allowProvisioningUpdates
    ;;
  help|--help|-h) usage ;;
  *) usage; exit 2 ;;
esac
