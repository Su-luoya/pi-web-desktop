#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/Pi-Web-Desktop.app"
DEST="$HOME/Applications/Pi-Web-Desktop.app"

if [ ! -d "$APP" ]; then
  "$ROOT/Scripts/build.sh"
fi

# 不留备份（需要旧版就从 git 重新构建），但也别在复制或签名中途失败时把还能用的旧版删掉：
# 先装到临时名字，校验通过再交换。
STAGE="$DEST.new"
rm -rf "$STAGE"
cp -R "$APP" "$STAGE"

# Finder/iCloud metadata on copied bundles can make ad-hoc signing fail.
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$STAGE" 2>/dev/null || true
  find "$STAGE" -print0 | while IFS= read -r -d '' item; do
    xattr -d com.apple.provenance "$item" 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$item" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$item" 2>/dev/null || true
  done
  xattr -d com.apple.FinderInfo "$STAGE" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$STAGE" 2>/dev/null || true
fi

codesign --force --deep --sign - "$STAGE" >/dev/null
# Copies made by synced folders may carry Finder metadata onto the bundle root.
if command -v xattr >/dev/null 2>&1; then
  xattr -d com.apple.FinderInfo "$STAGE" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$STAGE" 2>/dev/null || true
fi

codesign --verify --deep --strict "$STAGE" >/dev/null

rm -rf "$DEST"
mv "$STAGE" "$DEST"
printf 'Installed: %s\n' "$DEST"
