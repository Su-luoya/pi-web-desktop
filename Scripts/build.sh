#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Pi-Web-Desktop.app"
BIN="$APP/Contents/MacOS/PiWebDesktop"
SOURCE="$ROOT/Sources/PiWebApp.swift"
ICON="$ROOT/Resources/ApplicationIcon.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc "$ROOT/Sources/PiWebApp.swift" \
  "$ROOT/Sources/ServiceConfiguration.swift" \
  "$ROOT/Sources/PreferencesWindowController.swift" \
  "$ROOT/Sources/main.swift" \
  -target arm64-apple-macosx14.0 \
  -o "$BIN" \
  -framework Cocoa \
  -framework WebKit

if [ -f "$ICON" ]; then
  # Avoid preserving Finder/File Provider metadata into the app bundle.
  ditto --norsrc --noextattr "$ICON" "$APP/Contents/Resources/ApplicationIcon.icns"
fi

clear_metadata() {
  if ! command -v xattr >/dev/null 2>&1; then
    return
  fi

  xattr -cr "$APP" 2>/dev/null || true
  find "$APP" -print0 | while IFS= read -r -d '' item; do
    xattr -d com.apple.provenance "$item" 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$item" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$item" 2>/dev/null || true
  done
  # The bundle directory itself may receive Finder/File Provider metadata
  # from the parent directory after the recursive cleanup above.
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
}

# Finder/resource-fork metadata copied from user files can invalidate ad-hoc signing.
clear_metadata

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Pi Web Desktop</string>
    <key>CFBundleExecutable</key>
    <string>PiWebDesktop</string>
    <key>CFBundleIconFile</key>
    <string>ApplicationIcon</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.su-luoya.pi-web-desktop</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Pi Web Desktop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0-alpha.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
# The enclosing synced directory can reattach Finder metadata after signing.
if command -v xattr >/dev/null 2>&1; then
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
fi
codesign --verify --deep --strict "$APP" >/dev/null

printf 'Built: %s\n' "$APP"
file "$BIN"
