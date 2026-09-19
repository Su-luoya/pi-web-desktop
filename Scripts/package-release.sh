#!/bin/sh
set -eu

# Package an already built Pi Web Desktop bundle as the alpha release artifact.
# The same script is used locally and by .github/workflows/release.yml, so a
# rehearsal on a laptop exercises exactly the code path CI runs:
#
#   1. release tag / xcconfig version consistency  (Scripts/check-release-version.sh)
#   2. bundle identity and version                 (Scripts/check-identity.sh)
#   3. ad-hoc signature verification               (codesign --verify --deep --strict)
#   4. signature and Gatekeeper evidence           (codesign -dv --verbose=4, spctl -a -vv)
#   5. ZIP + SHA-256                               (ditto -c -k, shasum -a 256)
#   6. dist/release-metadata.env and the evidence section used in the release notes
#
# This script never runs xcodebuild and never signs anything. The bundle must
# already be ad-hoc signed by Scripts/build.sh (or Scripts/install.sh); a bundle
# with any other signature is refused, because the alpha release notes and the
# installation instructions document an ad-hoc, non-notarized build.
#
# Usage:
#   ./Scripts/package-release.sh [--app PATH] [--out DIR] [--tag TAG] [--build]
#
#   --app PATH   app bundle to package, default build/Pi-Web-Desktop.app
#   --out DIR    output directory, default dist/
#   --tag TAG    release tag forwarded to Scripts/check-release-version.sh;
#                without it that script reads GITHUB_REF_NAME, and with neither
#                the tag comparison is skipped (normal for a local rehearsal)
#   --build      run ./Scripts/build.sh first when the bundle is stale or absent
#
# Outputs (in DIR):
#   <App>-<MARKETING_VERSION>.zip            the release asset
#   <App>-<MARKETING_VERSION>.zip.sha256     portable "hash  name" checksum file
#   <App>-<MARKETING_VERSION>.evidence.md    signature/Gatekeeper evidence section
#   release-metadata.env                     shell assignments sourced by the workflow
#
# Exit status: 0 packaged, 1 a check or packaging step failed, 2 usage error.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

usage() {
  printf 'usage: ./Scripts/package-release.sh [--app PATH] [--out DIR] [--tag TAG] [--build]\n'
}

usage_error() {
  printf 'error: %s\n' "$1" >&2
  usage >&2
  exit 2
}

fail() {
  printf 'package-release: FAILED - %s\n' "$1" >&2
  exit 1
}

# Finder and the iCloud/File Provider stack attach extended attributes
# (com.apple.FinderInfo, com.apple.fileprovider.fpfs#P, ...) to files inside
# synced directories such as ~/Documents. codesign --verify --deep --strict
# rejects that "detritus" on the bundle or on its Mach-O executable, even when
# it was attached after signing; CI checks out into a clean directory, so this
# defensive cleanup matters for local work trees. Cleanup failures are warnings:
# the signature verification below stays the gate and is never skipped.
clear_extended_attributes() {
  [ -n "$1" ] || return 0
  if ! command -v xattr >/dev/null 2>&1; then
    printf 'warning: xattr is not available; skipping extended-attribute cleanup for %s\n' "$1" >&2
    printf 'warning: if signature verification fails with "resource fork, Finder information, or similar detritus not allowed", clear the attributes by hand (docs/releasing.md)\n' >&2
    return 0
  fi

  set +e
  xattr_output=$(xattr -cr "$1" 2>&1)
  xattr_status=$?
  set -e

  if [ "$xattr_status" -ne 0 ]; then
    printf 'warning: xattr -cr %s failed with status %s: %s\n' "$1" "$xattr_status" "$xattr_output" >&2
    printf 'warning: signature verification below reports any metadata that still breaks it\n' >&2
  fi
  return 0
}

APP=''
OUT=''
TAG=''
BUILD_FIRST=0

while [ "$#" -gt 0 ]; do
  case $1 in
    --app)
      [ "$#" -ge 2 ] || usage_error '--app requires a path'
      APP=$2
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || usage_error '--out requires a path'
      OUT=$2
      shift 2
      ;;
    --tag)
      [ "$#" -ge 2 ] || usage_error '--tag requires a tag name'
      TAG=$2
      shift 2
      ;;
    --build)
      BUILD_FIRST=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument $1"
      ;;
  esac
done

[ -n "$APP" ] || APP="$ROOT/build/Pi-Web-Desktop.app"
[ -n "$OUT" ] || OUT="$ROOT/dist"

if [ "$BUILD_FIRST" -eq 1 ]; then
  "$ROOT/Scripts/build.sh"
fi

[ -d "$APP" ] || fail "app bundle not found at $APP (run ./Scripts/build.sh first, or pass --app)"

# The caller's working directory must not leak into the evidence or the ZIP.
APP=$(CDPATH= cd -- "$(dirname -- "$APP")" && pwd)/$(basename -- "$APP")
APP_PARENT=$(dirname -- "$APP")
APP_BASENAME=$(basename -- "$APP")
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || fail "missing $PLIST"

if ! VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST" 2>/dev/null); then
  fail "cannot read CFBundleShortVersionString from $PLIST"
fi
if ! BUILD=$(plutil -extract CFBundleVersion raw -o - "$PLIST" 2>/dev/null); then
  fail "cannot read CFBundleVersion from $PLIST"
fi

# release-metadata.env is sourced by the workflow, so keep the value space small
# and reject anything that could turn into a surprising assignment.
case $VERSION in
  ''|*[!0-9A-Za-z._+-]*) fail "unsupported CFBundleShortVersionString '$VERSION' in $PLIST" ;;
esac
case $BUILD in
  ''|*[!0-9A-Za-z._+-]*) fail "unsupported CFBundleVersion '$BUILD' in $PLIST" ;;
esac

APP_STEM=${APP_BASENAME%.app}
[ -n "$APP_STEM" ] || fail "cannot derive an artifact name from '$APP_BASENAME'"

ZIP_NAME="$APP_STEM-$VERSION.zip"
EVIDENCE_NAME="$APP_STEM-$VERSION.evidence.md"

mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)

printf 'package-release: app %s (CFBundleShortVersionString %s, CFBundleVersion %s)\n' "$APP" "$VERSION" "$BUILD"

printf '\n== release version ==\n'
if [ -n "$TAG" ]; then
  "$ROOT/Scripts/check-release-version.sh" "$TAG"
else
  "$ROOT/Scripts/check-release-version.sh"
fi

printf '\n== bundle identity ==\n'
"$ROOT/Scripts/check-identity.sh" "$APP"

printf '\n== ad-hoc signature verification ==\n'
# Finder/iCloud metadata is cleared first so a stale work tree cannot fail the
# gate with "resource fork, Finder information, or similar detritus not allowed".
clear_extended_attributes "$APP"
VERIFY_ATTEMPT=0
while :; do
  VERIFY_ATTEMPT=$((VERIFY_ATTEMPT + 1))
  set +e
  VERIFY_OUTPUT=$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)
  VERIFY_STATUS=$?
  set -e
  if [ "$VERIFY_STATUS" -eq 0 ] || [ "$VERIFY_ATTEMPT" -ge 2 ]; then
    break
  fi
  printf 'warning: codesign --verify --deep --strict failed (attempt %s/2, status %s); clearing extended attributes and retrying\n' "$VERIFY_ATTEMPT" "$VERIFY_STATUS" >&2
  [ -z "$VERIFY_OUTPUT" ] || printf '%s\n' "$VERIFY_OUTPUT" >&2
  clear_extended_attributes "$APP"
  sleep 1
done
if [ -n "$VERIFY_OUTPUT" ]; then
  printf '%s\n' "$VERIFY_OUTPUT"
fi
if [ "$VERIFY_STATUS" -ne 0 ]; then
  printf 'package-release: hint: the bundle or its executable still carries metadata that ad-hoc verification rejects. Inspect it with "xattr -l %s" and clear it with "xattr -cr %s"; Finder and iCloud/File Provider attach com.apple.FinderInfo in synced directories such as ~/Documents. See docs/releasing.md.\n' "$APP" "$APP" >&2
  fail "codesign --verify --deep --strict failed with status $VERIFY_STATUS for $APP"
fi
printf 'ok   codesign --verify --deep --strict passed\n'

printf '\n== signature and Gatekeeper evidence ==\n'
set +e
CODESIGN_DV=$(codesign -dv --verbose=4 "$APP" 2>&1)
CODESIGN_DV_STATUS=$?
SPCTL_OUT=$(spctl -a -vv "$APP" 2>&1)
SPCTL_STATUS=$?
set -e

printf '%s\n' "$CODESIGN_DV"
if [ "$CODESIGN_DV_STATUS" -ne 0 ]; then
  fail "codesign -dv --verbose=4 failed with status $CODESIGN_DV_STATUS for $APP"
fi

SIGNATURE=$(printf '%s\n' "$CODESIGN_DV" | sed -n 's/^Signature=//p' | head -n 1)
TEAM_IDENTIFIER=$(printf '%s\n' "$CODESIGN_DV" | sed -n 's/^TeamIdentifier=//p' | head -n 1)

if [ "$SIGNATURE" != "adhoc" ]; then
  fail "$APP reports 'Signature=${SIGNATURE:-<missing>}' instead of 'Signature=adhoc'. This pipeline documents an ad-hoc, non-notarized alpha; a Developer ID or notarized build needs different release notes, install instructions and workflow steps (see docs/releasing.md), so packaging stops here."
fi
if [ "$TEAM_IDENTIFIER" != "not set" ]; then
  fail "$APP reports 'TeamIdentifier=$TEAM_IDENTIFIER' instead of 'TeamIdentifier=not set'; an ad-hoc build has no team, so the bundle is not the artifact this pipeline documents"
fi
printf 'ok   signature is ad-hoc (TeamIdentifier=not set), not notarized\n'

printf '%s\n' "$SPCTL_OUT"
if [ "$SPCTL_STATUS" -eq 0 ]; then
  SPCTL_NOTE='spctl accepted the bundle on this machine; that is a local Gatekeeper decision, not a notarization or signing claim'
else
  SPCTL_NOTE="spctl exited with status $SPCTL_STATUS: Gatekeeper did not accept the bundle, which is the expected result for an ad-hoc, non-notarized app"
fi
printf 'info %s\n' "$SPCTL_NOTE"

printf '\n== packaging ==\n'
# Keep Finder/File Provider metadata out of the ZIP too: ditto would otherwise
# store it in __MACOSX/ AppleDouble entries and restore it on the user's
# machine. The bundle was already verified above and cleaning xattrs does not
# touch the code signature.
clear_extended_attributes "$APP"
( cd "$APP_PARENT" && ditto -c -k --sequesterRsrc --keepParent "$APP_BASENAME" "$OUT/$ZIP_NAME" )
( cd "$OUT" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256" )
SHA256=$(awk '{print $1}' "$OUT/$ZIP_NAME.sha256")
[ -n "$SHA256" ] || fail "cannot read the SHA-256 of $ZIP_NAME"

# Verify the checksum file with the same command the release notes give users.
( cd "$OUT" && shasum -a 256 -c "$ZIP_NAME.sha256" )

if command -v unzip >/dev/null 2>&1; then
  if unzip -l "$OUT/$ZIP_NAME" | grep -q "$APP_BASENAME/Contents/MacOS/"; then
    printf 'ok   %s contains %s/Contents/MacOS/\n' "$ZIP_NAME" "$APP_BASENAME"
  else
    fail "$ZIP_NAME does not contain $APP_BASENAME/Contents/MacOS/"
  fi
fi

COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)
[ -n "$COMMIT" ] || COMMIT=unknown
if [ "$COMMIT" != "unknown" ] && [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null || true)" ]; then
  WORKTREE='dirty (packaged from a working tree with uncommitted changes)'
else
  WORKTREE='clean'
fi
SW_VERS=$(sw_vers -productVersion 2>/dev/null || true)
[ -n "$SW_VERS" ] || SW_VERS='unknown'
ARCH=$(uname -m)

printf '\n== release notes evidence section ==\n'
{
  printf '## 签名与公证证据（由 Scripts/package-release.sh 自动生成）\n\n'
  printf '%s\n' "- 应用包：\"$APP_BASENAME\"（CFBundleShortVersionString=${VERSION}，CFBundleVersion=${BUILD}）"
  printf '%s\n' "- ZIP：\"$ZIP_NAME\""
  printf '%s\n' "- SHA-256：\"$SHA256\""
  printf '%s\n' "- 构建提交：\"$COMMIT\"，工作区 $WORKTREE"
  printf '%s\n' "- 打包环境（本机或 CI runner，不等同于 Release Issue 中记录的真机实测环境）：macOS ${SW_VERS}，${ARCH}"
  printf '%s\n' '- 签名类型：**adhoc**。codesign 报告 "Signature=adhoc" 与 "TeamIdentifier=not set"：没有 Developer ID 证书，也不是经过 Apple 公证的发行版。'
  printf '%s\n' '- Apple 公证：**未公证**。本项目没有 Apple Developer 账号，发布流程不执行公证。'
  printf '%s\n' "- \"codesign --verify --deep --strict\"：退出码 ${VERIFY_STATUS}（通过），签名与资源封条未损坏。"
  printf '%s\n' "- \"spctl -a -vv\"：退出码 ${SPCTL_STATUS}。${SPCTL_NOTE}"
  printf '\n<details>\n<summary>codesign -dv --verbose=4 原始输出（退出码 %s）</summary>\n\n```text\n' "$CODESIGN_DV_STATUS"
  printf '%s\n' "$CODESIGN_DV"
  printf '```\n\n</details>\n'
  printf '\n<details>\n<summary>spctl -a -vv 原始输出（退出码 %s）</summary>\n\n```text\n' "$SPCTL_STATUS"
  printf '%s\n' "$SPCTL_OUT"
  printf '```\n\n</details>\n'
  printf '\n> 未公证不是可以忽略的细节：首次打开需要在 macOS 中针对该应用手动放行（右键打开，或在“系统设置 → 隐私与安全性”中选择“仍要打开”）。不要关闭 Gatekeeper，也不要执行全局关闭的指令。\n'
} > "$OUT/$EVIDENCE_NAME"

{
  printf '# Generated by Scripts/package-release.sh -- do not edit.\n'
  printf '# Sourced by .github/workflows/release.yml to render the release notes.\n'
  printf 'VERSION=%s\n' "$VERSION"
  printf 'BUILD=%s\n' "$BUILD"
  printf 'APP_NAME=%s\n' "$APP_BASENAME"
  printf 'ZIP_NAME=%s\n' "$ZIP_NAME"
  printf 'SHA256=%s\n' "$SHA256"
  printf 'EVIDENCE_NAME=%s\n' "$EVIDENCE_NAME"
  printf 'COMMIT=%s\n' "$COMMIT"
} > "$OUT/release-metadata.env"

printf '\npackage-release: OK\n'
printf '  app:       %s\n' "$APP"
printf '  version:   %s (build %s)\n' "$VERSION" "$BUILD"
printf '  zip:       %s\n' "$OUT/$ZIP_NAME"
printf '  sha256:    %s\n' "$OUT/$ZIP_NAME.sha256"
printf '  evidence:  %s\n' "$OUT/$EVIDENCE_NAME"
printf '  metadata:  %s\n' "$OUT/release-metadata.env"
printf '  signature: adhoc (TeamIdentifier=not set), not notarized\n'
exit 0
