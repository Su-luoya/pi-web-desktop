#!/bin/sh
set -eu

# Run the XCTest suite through xcodebuild.
#
# Usage:
#   ./Scripts/test.sh [extra xcodebuild arguments...]
#
# Why this wrapper exists: day-to-day builds here go through
# ./Scripts/build.sh, which calls swiftc directly, so `xcode-select -p` is often
# still /Library/Developer/CommandLineTools even when Xcode is installed. In
# that state xcodebuild refuses to run at all:
#
#   xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer
#   directory '/Library/Developer/CommandLineTools' is a command line tools
#   instance
#
# Switching the machine-wide developer directory needs sudo
# (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`). This
# script does not touch that setting: it exports DEVELOPER_DIR for one
# invocation, which is the same switch scoped to this process, so a stray
# `git`/`clang` invocation elsewhere on the machine keeps its current behaviour.
#
# Developer directory resolution:
#   1. DEVELOPER_DIR already set in the environment -> used as-is.
#   2. xcode-select already points at a full Xcode -> used as-is.
#   3. $XCODE_APP (default /Applications/Xcode.app) exists -> used for this run.
#   4. nothing usable -> exit 2 with the remedial command.
#
# DerivedData defaults to .build/DerivedData (git-ignored) instead of
# ~/Library/Developer/Xcode/DerivedData, so test runs do not pile up in the
# shared location; override with DERIVED_DATA_PATH.
#
# This script runs XCTest only. The full local sequence in CONTRIBUTING.md also
# runs `build` and hands the .xctest bundle to ./Scripts/check-identity.sh.
#
# Exit status: 0 tests passed, 1 test or build failure, 2 usage/environment error.

usage() {
  printf 'usage: ./Scripts/test.sh [extra xcodebuild arguments...]\n'
}

case ${1:-} in
  -h|--help)
    usage
    exit 0
    ;;
esac

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
XCODE_APP=${XCODE_APP:-/Applications/Xcode.app}
DERIVED_DATA_PATH=${DERIVED_DATA_PATH:-$PROJECT_DIR/.build/DerivedData}

if [ -z "${DEVELOPER_DIR:-}" ]; then
  active_developer_dir=$(/usr/bin/xcode-select -p 2>/dev/null || true)
  case $active_developer_dir in
    */Xcode*.app/Contents/Developer)
      # xcode-select already points at Xcode; nothing to override.
      ;;
    *)
      if [ -d "$XCODE_APP/Contents/Developer" ]; then
        DEVELOPER_DIR=$XCODE_APP/Contents/Developer
        export DEVELOPER_DIR
        printf 'test: xcode-select is %s, using DEVELOPER_DIR=%s for this run\n' \
          "${active_developer_dir:-<unset>}" "$DEVELOPER_DIR" >&2
      else
        printf 'error: no full Xcode available\n' >&2
        printf '  xcode-select -p reports: %s\n' "${active_developer_dir:-<unset>}" >&2
        printf '  looked for: %s\n' "$XCODE_APP/Contents/Developer" >&2
        printf '  fix one of: install Xcode, set XCODE_APP=<path to Xcode.app>,\n' >&2
        printf '              or run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer\n' >&2
        exit 2
      fi
      ;;
  esac
fi

set -- \
  -project "$PROJECT_DIR/PiWebDesktop.xcodeproj" \
  -scheme PiWebDesktop \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "$@"

exec /usr/bin/xcodebuild test "$@"
