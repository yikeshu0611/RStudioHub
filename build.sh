#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RStudioHub"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
STAGING_DIR="$BUILD_DIR/dmg-root"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
ICON_PNG="$BUILD_DIR/AppIcon-1024.png"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DIST_DIR"

swift "$ROOT_DIR/Tools/MakeIcon.swift" "$ICON_PNG"
mkdir -p "$ICONSET_DIR"
sips -z 16 16 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ICON_PNG" "$APP_DIR/Contents/Resources/AppIcon.png"

DYLIB_PATH="$BUILD_DIR/DockHide.dylib"
clang -dynamiclib -arch arm64e -mmacosx-version-min=12.0 -framework AppKit \
  -o "$DYLIB_PATH" "$ROOT_DIR/Sources/DockHide/dockhide.m"
cp "$DYLIB_PATH" "$APP_DIR/Contents/Resources/DockHide.dylib"
codesign --force --sign - "$DYLIB_PATH" 2>/dev/null || true

SWIFT_SOURCES=(
  "$ROOT_DIR/Sources/ActivityLogger.swift"
  "$ROOT_DIR/Sources/RStudioInstance.swift"
  "$ROOT_DIR/Sources/ProjectHistoryStore.swift"
  "$ROOT_DIR/Sources/RStudioRecentProjects.swift"
  "$ROOT_DIR/Sources/RStudioRecentFiles.swift"
  "$ROOT_DIR/Sources/RStudioSessionProjects.swift"
  "$ROOT_DIR/Sources/MenuTabBarView.swift"
  "$ROOT_DIR/Sources/MenuRowHoverView.swift"
  "$ROOT_DIR/Sources/MenuLayout.swift"
  "$ROOT_DIR/Sources/ProjectMenuRowView.swift"
  "$ROOT_DIR/Sources/InstanceMenuRowView.swift"
  "$ROOT_DIR/Sources/ActionButtonsView.swift"
  "$ROOT_DIR/Sources/HubShortcut.swift"
  "$ROOT_DIR/Sources/GlobalShortcutService.swift"
  "$ROOT_DIR/Sources/ShortcutSettingsRowView.swift"
  "$ROOT_DIR/Sources/ShortcutRecordingPanel.swift"
  "$ROOT_DIR/Sources/LaunchAtLoginSettings.swift"
  "$ROOT_DIR/Sources/HubAppPolicy.swift"
  "$ROOT_DIR/Sources/HubNameSort.swift"
  "$ROOT_DIR/Sources/HubUpdateService.swift"
  "$ROOT_DIR/Sources/HubMenuBarBuilder.swift"
  "$ROOT_DIR/Sources/RStudioMenuBridge.swift"
  "$ROOT_DIR/Sources/HubDockMenuBuilder.swift"
  "$ROOT_DIR/Sources/ProcessTransform.swift"
  "$ROOT_DIR/Sources/DockPolicyService.swift"
  "$ROOT_DIR/Sources/RStudioHubApp.swift"
  "$ROOT_DIR/Sources/main.swift"
)

clang -c -mmacosx-version-min=12.0 -arch arm64 \
  -o "$BUILD_DIR/ProcessTransform-arm64.o" \
  "$ROOT_DIR/Sources/ProcessTransform.c"
clang -c -mmacosx-version-min=12.0 -arch arm64 \
  -o "$BUILD_DIR/ProcessArguments-arm64.o" \
  "$ROOT_DIR/Sources/ProcessArguments.c"
if [[ "$(uname -m)" == "arm64" ]]; then
  clang -c -mmacosx-version-min=12.0 -arch x86_64 \
    -o "$BUILD_DIR/ProcessTransform-x86_64.o" \
    "$ROOT_DIR/Sources/ProcessTransform.c" 2>/dev/null || true
  clang -c -mmacosx-version-min=12.0 -arch x86_64 \
    -o "$BUILD_DIR/ProcessArguments-x86_64.o" \
    "$ROOT_DIR/Sources/ProcessArguments.c" 2>/dev/null || true
fi

swiftc \
  -O \
  -whole-module-optimization \
  -target arm64-apple-macos12.0 \
  "${SWIFT_SOURCES[@]}" \
  "$BUILD_DIR/ProcessTransform-arm64.o" \
  "$BUILD_DIR/ProcessArguments-arm64.o" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework ServiceManagement \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"

if [[ "$(uname -m)" == "arm64" ]]; then
  TMP_ARM="$BUILD_DIR/$APP_NAME-arm64"
  TMP_X86="$BUILD_DIR/$APP_NAME-x86_64"
  cp "$APP_DIR/Contents/MacOS/$APP_NAME" "$TMP_ARM"
  if [[ -f "$BUILD_DIR/ProcessTransform-x86_64.o" && -f "$BUILD_DIR/ProcessArguments-x86_64.o" ]] && swiftc \
    -O \
    -whole-module-optimization \
    -target x86_64-apple-macos12.0 \
    "${SWIFT_SOURCES[@]}" \
    "$BUILD_DIR/ProcessTransform-x86_64.o" \
    "$BUILD_DIR/ProcessArguments-x86_64.o" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Carbon \
    -framework ServiceManagement \
    -o "$TMP_X86" 2>/dev/null; then
    lipo -create "$TMP_ARM" "$TMP_X86" -output "$APP_DIR/Contents/MacOS/$APP_NAME"
  fi
fi

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_DIR/Contents/Info.plist"

codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto --norsrc --noextattr "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -sf /Applications "$STAGING_DIR/Applications"
xattr -cr "$STAGING_DIR/$APP_NAME.app" 2>/dev/null || true

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

cp "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
xattr -cr "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg" 2>/dev/null || true

echo "Built $APP_DIR"
echo "Built $DMG_PATH"
ls -lh "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
