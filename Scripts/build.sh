#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
XCCONFIG_REL="Configuration/AppIdentity.xcconfig"
XCCONFIG="$ROOT/$XCCONFIG_REL"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Pi-Web-Desktop.app"

# Read one value from the single-source xcconfig, expanding $(VAR) references,
# so this script and PiWebDesktop.xcodeproj always agree on identity and version.
xcconfig_value() {
  awk -v key="$1" '
    function trim(text) {
      gsub(/^[[:space:]]+/, "", text)
      gsub(/[[:space:]]+$/, "", text)
      return text
    }
    {
      line = $0
      sub(/\/\/.*/, "", line)
      if (line ~ /^[[:space:]]*#/) next
      eq = index(line, "=")
      if (eq == 0) next
      name = trim(substr(line, 1, eq - 1))
      if (name != "") values[name] = trim(substr(line, eq + 1))
    }
    END {
      value = values[key]
      for (pass = 0; pass < 5; pass++) {
        expanded = value
        while (match(expanded, /\$\([A-Za-z_][A-Za-z0-9_]*\)/)) {
          ref = substr(expanded, RSTART + 2, RLENGTH - 3)
          if (!(ref in values)) break
          expanded = substr(expanded, 1, RSTART - 1) values[ref] substr(expanded, RSTART + RLENGTH)
        }
        if (expanded == value) break
        value = expanded
      }
      print value
    }
  ' "$XCCONFIG"
}

require_value() {
  if [ -z "$2" ]; then
    printf 'error: %s is missing from %s\n' "$1" "$XCCONFIG_REL" >&2
    exit 1
  fi
  case $2 in
    *'<'*|*'>'*|*'&'*)
      printf 'error: %s contains XML characters that cannot be written to Info.plist\n' "$1" >&2
      exit 1
      ;;
  esac
}

if [ ! -f "$XCCONFIG" ]; then
  printf 'error: missing %s\n' "$XCCONFIG_REL" >&2
  exit 1
fi

APP_DISPLAY_NAME=$(xcconfig_value APP_DISPLAY_NAME)
APP_BUNDLE_NAME=$(xcconfig_value APP_BUNDLE_NAME)
APP_EXECUTABLE_NAME=$(xcconfig_value APP_EXECUTABLE_NAME)
APP_ICON_NAME=$(xcconfig_value APP_ICON_NAME)
APP_MINIMUM_SYSTEM_VERSION=$(xcconfig_value APP_MINIMUM_SYSTEM_VERSION)
APP_BUNDLE_IDENTIFIER=$(xcconfig_value PRODUCT_BUNDLE_IDENTIFIER)
APP_VERSION=$(xcconfig_value MARKETING_VERSION)
APP_BUILD=$(xcconfig_value CURRENT_PROJECT_VERSION)

require_value APP_DISPLAY_NAME "$APP_DISPLAY_NAME"
require_value APP_BUNDLE_NAME "$APP_BUNDLE_NAME"
require_value APP_EXECUTABLE_NAME "$APP_EXECUTABLE_NAME"
require_value APP_ICON_NAME "$APP_ICON_NAME"
require_value APP_MINIMUM_SYSTEM_VERSION "$APP_MINIMUM_SYSTEM_VERSION"
require_value PRODUCT_BUNDLE_IDENTIFIER "$APP_BUNDLE_IDENTIFIER"
require_value MARKETING_VERSION "$APP_VERSION"
require_value CURRENT_PROJECT_VERSION "$APP_BUILD"

BIN="$APP/Contents/MacOS/$APP_EXECUTABLE_NAME"
ICON="$ROOT/Resources/$APP_ICON_NAME.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc "$ROOT/Sources/PiWebApp.swift" \
  "$ROOT/Sources/AppConfiguration.swift" \
  "$ROOT/Sources/AppPaths.swift" \
  "$ROOT/Sources/DiagnosticsCollector.swift" \
  "$ROOT/Sources/DependencyChecker.swift" \
  "$ROOT/Sources/FirstLaunchDiagnostics.swift" \
  "$ROOT/Sources/InstallCommandManifest.swift" \
  "$ROOT/Sources/KeychainStore.swift" \
  "$ROOT/Sources/ProcessInspector.swift" \
  "$ROOT/Sources/QuitPolicy.swift" \
  "$ROOT/Sources/ServiceConfiguration.swift" \
  "$ROOT/Sources/ServiceManager.swift" \
  "$ROOT/Sources/ServiceOwnership.swift" \
  "$ROOT/Sources/WebViewController.swift" \
  "$ROOT/Sources/WebViewNavigationPolicy.swift" \
  "$ROOT/Sources/WorkspaceDirectory.swift" \
  "$ROOT/Sources/PreferencesWindowController.swift" \
  "$ROOT/Sources/DiagnosticsWindowController.swift" \
  "$ROOT/Sources/main.swift" \
  -target "arm64-apple-macosx$APP_MINIMUM_SYSTEM_VERSION" \
  -o "$BIN" \
  -framework Cocoa \
  -framework WebKit

if [ -f "$ICON" ]; then
  # Avoid preserving Finder/File Provider metadata into the app bundle.
  ditto --norsrc --noextattr "$ICON" "$APP/Contents/Resources/$APP_ICON_NAME.icns"
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

# Identity and version come from Configuration/AppIdentity.xcconfig only.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_EXECUTABLE_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$APP_ICON_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$APP_BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_BUNDLE_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>$APP_MINIMUM_SYSTEM_VERSION</string>
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
