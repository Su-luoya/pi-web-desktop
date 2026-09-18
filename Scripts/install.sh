#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/Pi-Web-Desktop.app"
DEST="$HOME/Applications/Pi-Web-Desktop.app"

if [ ! -d "$APP" ]; then
  "$ROOT/Scripts/build.sh"
fi

if [ -e "$DEST" ]; then
  BACKUP="$HOME/Applications/Pi-Web-Desktop.backup.$(date +%Y%m%d-%H%M%S).app"
  mv "$DEST" "$BACKUP"
  printf 'Backed up existing app to: %s\n' "$BACKUP"
fi

cp -R "$APP" "$DEST"

# Finder/iCloud metadata on copied bundles can make ad-hoc signing fail.
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$DEST" 2>/dev/null || true
  find "$DEST" -print0 | while IFS= read -r -d '' item; do
    xattr -d com.apple.provenance "$item" 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$item" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$item" 2>/dev/null || true
  done
  xattr -d com.apple.FinderInfo "$DEST" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$DEST" 2>/dev/null || true
fi

codesign --force --deep --sign - "$DEST" >/dev/null
# Copies made by synced folders may carry Finder metadata onto the bundle root.
if command -v xattr >/dev/null 2>&1; then
  xattr -d com.apple.FinderInfo "$DEST" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$DEST" 2>/dev/null || true
fi

codesign --verify --deep --strict "$DEST" >/dev/null
printf 'Installed: %s\n' "$DEST"
