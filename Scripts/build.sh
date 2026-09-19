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
  "$ROOT/Sources/DiagnosticsClipboard.swift" \
  "$ROOT/Sources/ComponentInstallation.swift" \
  "$ROOT/Sources/UpdateChecker.swift" \
  "$ROOT/Sources/UpdateSettings.swift" \
  "$ROOT/Sources/DependencyChecker.swift" \
  "$ROOT/Sources/FirstLaunchDiagnostics.swift" \
  "$ROOT/Sources/InstallCommandManifest.swift" \
  "$ROOT/Sources/KeychainStore.swift" \
  "$ROOT/Sources/LogRedactor.swift" \
  "$ROOT/Sources/LogWriter.swift" \
  "$ROOT/Sources/ProcessInspector.swift" \
  "$ROOT/Sources/QuitPolicy.swift" \
  "$ROOT/Sources/ServiceConfiguration.swift" \
  "$ROOT/Sources/ServiceManager.swift" \
  "$ROOT/Sources/ServiceOwnership.swift" \
  "$ROOT/Sources/WebViewController.swift" \
  "$ROOT/Sources/WebViewNavigationPolicy.swift" \
  "$ROOT/Sources/WorkspaceDirectory.swift" \
  "$ROOT/Sources/PreferencesWindowController.swift" \
  "$ROOT/Sources/UpdateSettingsWindowController.swift" \
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

# Finder and the iCloud/File Provider stack attach extended attributes
# (com.apple.FinderInfo, com.apple.fileprovider.fpfs#P, ...) to files inside
# synced directories such as ~/Documents. codesign --verify --deep --strict
# rejects that "detritus" on the bundle or on the Mach-O executable, even when
# it was attached after signing. CI checks out into a clean directory, so only
# synced local work trees hit this.
clear_extended_attributes() {
  if ! command -v xattr >/dev/null 2>&1; then
    printf 'warning: xattr is not available; skipping extended-attribute cleanup for %s\n' "$APP" >&2
    printf 'warning: if the signature check fails with "resource fork, Finder information, or similar detritus not allowed", clear the attributes by hand (docs/development.md, section 构建)\n' >&2
    return 0
  fi

  set +e
  xattr_output=$(xattr -cr "$APP" 2>&1)
  xattr_status=$?
  set -e

  if [ "$xattr_status" -ne 0 ]; then
    printf 'warning: xattr -cr %s failed with status %s: %s\n' "$APP" "$xattr_status" "$xattr_output" >&2
    printf 'warning: the signature check below reports any metadata that still breaks verification\n' >&2
  fi
  return 0
}

verify_ad_hoc_signature() {
  attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    set +e
    verify_output=$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)
    verify_status=$?
    set -e

    if [ "$verify_status" -eq 0 ]; then
      if [ "$attempt" -gt 1 ]; then
        printf 'info: codesign --verify --deep --strict passed on attempt %s (Finder/File Provider metadata was reattached after signing)\n' "$attempt"
      fi
      return 0
    fi

    if [ "$attempt" -lt 3 ]; then
      printf 'warning: codesign --verify --deep --strict failed (attempt %s/3, status %s); clearing extended attributes and retrying\n' "$attempt" "$verify_status" >&2
      [ -z "$verify_output" ] || printf '%s\n' "$verify_output" >&2
      clear_extended_attributes
      sleep 1
    fi
  done

  printf 'error: codesign --verify --deep --strict failed for %s (status %s)\n' "$APP" "$verify_status" >&2
  [ -z "$verify_output" ] || printf '%s\n' "$verify_output" >&2
  printf 'error: the bundle or its executable carries metadata that ad-hoc verification rejects.\n' >&2
  printf 'error: inspect with "xattr -l %s" and clear with "xattr -cr %s", then rebuild; see docs/development.md (section 构建).\n' "$APP" "$APP" >&2
  exit 1
}

# Finder/resource-fork metadata copied from user files can invalidate ad-hoc signing.
clear_extended_attributes

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

if ! codesign --force --deep --sign - "$APP" >/dev/null; then
  printf 'error: codesign --force --deep --sign - failed for %s\n' "$APP" >&2
  printf 'error: if the message mentions "resource fork, Finder information, or similar detritus not allowed", clear the attributes with "xattr -cr %s" and retry (see docs/development.md, section 构建).\n' "$APP" >&2
  exit 1
fi
# The enclosing synced directory can reattach Finder metadata after signing
# (for example com.apple.FinderInfo on the bundle or its executable), so clean
# again and verify with retries before declaring the build good.
clear_extended_attributes
verify_ad_hoc_signature

printf 'Built: %s\n' "$APP"
file "$BIN"
