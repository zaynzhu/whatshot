#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_DIR=${SCRIPT_DIR:h}
MACOS_PACKAGE_DIR="$REPOSITORY_DIR/macos"
OUTPUT_DIR="$REPOSITORY_DIR/dist"
OUTPUT_APP="$OUTPUT_DIR/WhatShot.app"
STAGING_DIR=$(mktemp -d /tmp/whatshot-app.XXXXXX)
STAGING_APP="$STAGING_DIR/WhatShot.app"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

swift build --package-path "$MACOS_PACKAGE_DIR" --configuration release
RELEASE_BIN_DIR=$(swift build --package-path "$MACOS_PACKAGE_DIR" --configuration release --show-bin-path)

mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
cp "$RELEASE_BIN_DIR/WhatShotApp" "$STAGING_APP/Contents/MacOS/WhatShot"

INFO_PLIST="$STAGING_APP/Contents/Info.plist"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict/>\n</plist>\n' > "$INFO_PLIST"
plutil -insert CFBundleDisplayName -string WhatShot "$INFO_PLIST"
plutil -insert CFBundleExecutable -string WhatShot "$INFO_PLIST"
plutil -insert CFBundleIdentifier -string com.zaynzhu.whatshot "$INFO_PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$INFO_PLIST"
plutil -insert CFBundleName -string WhatShot "$INFO_PLIST"
plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
plutil -insert CFBundleShortVersionString -string 1.0.0 "$INFO_PLIST"
plutil -insert CFBundleVersion -string 1 "$INFO_PLIST"
plutil -insert LSApplicationCategoryType -string public.app-category.entertainment "$INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string 14.0 "$INFO_PLIST"
plutil -insert LSUIElement -bool true "$INFO_PLIST"
plutil -insert NSHighResolutionCapable -bool true "$INFO_PLIST"

codesign --force --deep --sign - "$STAGING_APP"
codesign --verify --deep --strict "$STAGING_APP"

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_APP"
mv "$STAGING_APP" "$OUTPUT_APP"

print "Built $OUTPUT_APP"