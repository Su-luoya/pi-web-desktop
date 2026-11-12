#!/bin/sh
set -eu

# Zero-regression gate for strict concurrency.
#
# Usage:
#   ./Scripts/check-concurrency.sh
#
# Why this script exists: in Swift 5 language mode the compiler says nothing
# about cross-isolation access, so "this closure might not run on the main
# actor" regressions stay invisible until they corrupt AppKit state at runtime.
# `-strict-concurrency=complete` finds them, but running it by hand means
# nobody runs it. This is the tripwire: it type-checks every file under
# Sources/ once, and fails only when the result gets *worse* than the recorded
# baseline, so it is green on today's tree and red on tomorrow's regression.
#
# Two further gates cover the escape hatches that make a warning count lie:
#
#   1. `nonisolated(unsafe)` silences the checker while changing nothing at
#      runtime. Every remaining use is a reviewed ownership transfer or a
#      dispatch-work-item wrapper (see the comment at each site). A new one has
#      to go through review, not through `git commit -a`, so anything outside
#      the reviewed shapes fails.
#   2. The annotation count is baselined too, so nobody "fixes" a warning by
#      adding a fourth `nonisolated(unsafe)`.
#
# Developer directory resolution matches ./Scripts/test.sh (see the long note
# there); this script only needs swiftc, so CommandLineTools alone is enough.
#
# Exit status: 0 no regression, 1 regression, 2 usage/environment error.

# Baseline recorded after the strict-concurrency pass landed. Raise the
# warning baseline only if a new warning is genuinely unactionable; prefer
# fixing it.
WARNING_BASELINE=0
ANNOTATION_BASELINE=12

# The reviewed `nonisolated(unsafe)` shapes. Everything else fails gate 1.
#
#   let payload = work          dispatch-work-item wrapper / one-shot delivery
#   let deliver = completion    closure ownership handed to a queue or URLSession
#   let item = DispatchWorkItem same wrapper, reused by a repeating Timer
#   static let shared = ...     process-wide cache whose state is lock- or
#                               queue-protected inside the type
#   static let defaultStartTimeFormat  pure function, allocates per call
ALLOWED_ANNOTATIONS='let (payload = work|deliver = completion|item = DispatchWorkItem)|static let shared = DesktopUpdatePackageCache\(\)|static let defaultStartTimeFormat'

usage() {
  printf 'usage: ./Scripts/check-concurrency.sh\n'
}

case ${1:-} in
  -h|--help)
    usage
    exit 0
    ;;
esac

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
XCODE_APP=${XCODE_APP:-/Applications/Xcode.app}
WORK_DIR=$PROJECT_DIR/.build/concurrency

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$XCODE_APP/Contents/Developer" ]; then
  DEVELOPER_DIR=$XCODE_APP/Contents/Developer
  export DEVELOPER_DIR
fi

SWIFTC=${SWIFTC:-}
if [ -z "$SWIFTC" ]; then
  if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    printf 'error: no swiftc available\n' >&2
    printf '  fix one of: install Xcode, set XCODE_APP=<path to Xcode.app>,\n' >&2
    printf '              or set SWIFTC=<path to swiftc>\n' >&2
    exit 2
  fi
  SWIFTC=/usr/bin/xcrun
  SWIFTC_ARG=swiftc
else
  SWIFTC_ARG=
fi

# The SDK is resolved through xcrun rather than baked in: invoking the raw
# toolchain binary directly loses SDKROOT and fails with
#   <unknown>:0: error: unable to load standard library for target '...'
SDK_PATH=$(/usr/bin/xcrun --show-sdk-path 2>/dev/null || true)

# Deployment target comes from the same xcconfig the app builds with, so this
# check never disagrees with the real build about available API.
MACOS_VERSION=$(sed -n 's/^APP_MINIMUM_SYSTEM_VERSION *= *//p' \
  "$PROJECT_DIR/Configuration/AppIdentity.xcconfig" | head -1)
: "${MACOS_VERSION:=26.0}"
TARGET="$(/usr/bin/uname -m)-apple-macosx$MACOS_VERSION"

mkdir -p "$WORK_DIR"

cd "$PROJECT_DIR"
/usr/bin/find Sources -name '*.swift' | LC_ALL=C sort > "$WORK_DIR/sources.txt"

status=0

# --- gate 1 and 2: the escape hatch stays closed -----------------------------

# Matches the annotation wherever it sits in a declaration (`nonisolated(unsafe)
# let x`, `private nonisolated(unsafe) var y`) but not inside comments, so the
# prose that explains each site does not trip the gate.
/usr/bin/grep -rn 'nonisolated(unsafe)' --include='*.swift' Sources \
  | /usr/bin/grep -vE ':[0-9]+:[[:space:]]*(///|//|\*)' \
  | /usr/bin/grep -E 'nonisolated\(unsafe\)' \
  | LC_ALL=C sort > "$WORK_DIR/annotations.txt" || true

annotation_count=$(/usr/bin/wc -l < "$WORK_DIR/annotations.txt" | tr -d ' ')
if [ "$annotation_count" -gt "$ANNOTATION_BASELINE" ]; then
  printf 'concurrency: nonisolated(unsafe) count is %s, baseline is %s\n' \
    "$annotation_count" "$ANNOTATION_BASELINE" >&2
  status=1
fi

unreviewed=$(/usr/bin/grep -vE "$ALLOWED_ANNOTATIONS" "$WORK_DIR/annotations.txt" || true)
if [ -n "$unreviewed" ]; then
  printf 'concurrency: unreviewed nonisolated(unsafe):\n%s\n' "$unreviewed" >&2
  printf '  pick a different tool first: DispatchWorkItem for a queue hop, an\n' >&2
  printf '  explicit Sendable container for ownership transfer, @MainActor for\n' >&2
  printf '  isolation. If none fit, add the shape to ALLOWED_ANNOTATIONS here.\n' >&2
  status=1
fi

# --- gate 3: the warning count -------------------------------------------------

# `-c -wmo`而不只 `-typecheck`：Swift 6 的部分规则在 SIL 阶段才检查（例如从
# nonisolated `deinit` 访问非 Sendable 属性），`-typecheck` 会漏掉它们。这里
# 真的出目标文件（写到 .build/concurrency 下，不污染仓库），求快不加 -O。
swiftc_status=0
# shellcheck disable=SC2086
"$SWIFTC" $SWIFTC_ARG -c -wmo \
  -swift-version 6 \
  -strict-concurrency=complete \
  -sdk "$SDK_PATH" \
  -target "$TARGET" \
  -o "$WORK_DIR/check.o" \
  @"$WORK_DIR/sources.txt" \
  -framework Cocoa \
  -framework WebKit \
  -framework SystemConfiguration \
  > "$WORK_DIR/check.log" 2>&1 || swiftc_status=$?

# Only ``path:line:col: warning|error:`` counts. The diagnostic renderer echoes
# source lines and repeats note text that contains the word "warning", so a
# plain grep for `warning:` overcounts.
warning_count=$(/usr/bin/grep -cE '^[^:]+\.swift:[0-9]+:[0-9]+: warning: ' "$WORK_DIR/check.log" || true)
error_count=$(/usr/bin/grep -cE '^[^:]+\.swift:[0-9]+:[0-9]+: error: ' "$WORK_DIR/check.log" || true)

# A non-zero status with no parsed diagnostic means the check itself broke
# (bad toolchain, unreadable SDK). Reporting "clean" there would be worse than
# not having the gate at all.
if [ "$swiftc_status" -ne 0 ] && [ "$error_count" -eq 0 ]; then
  printf 'concurrency: the type-check did not run (status %s)\n' "$swiftc_status" >&2
  /usr/bin/tail -5 "$WORK_DIR/check.log" >&2
  exit 2
fi

if [ "$error_count" -gt 0 ]; then
  printf 'concurrency: %s type-checking error(s), see %s\n' \
    "$error_count" "$WORK_DIR/check.log" >&2
  /usr/bin/grep -E '^[^:]+\.swift:[0-9]+:[0-9]+: error: ' "$WORK_DIR/check.log" | sort -u >&2
  status=1
fi

if [ "$warning_count" -gt "$WARNING_BASELINE" ]; then
  printf 'concurrency: %s strict warning(s), baseline is %s\n' \
    "$warning_count" "$WARNING_BASELINE" >&2
  /usr/bin/grep -E '^[^:]+\.swift:[0-9]+:[0-9]+: warning: ' "$WORK_DIR/check.log" \
    | sort -u | sed 's/ \[#.*//' >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  printf 'concurrency: clean (%s files, %s baseline annotations)\n' \
    "$(/usr/bin/wc -l < "$WORK_DIR/sources.txt" | tr -d ' ')" "$annotation_count"
fi
exit "$status"
