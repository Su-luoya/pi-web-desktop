#!/bin/sh
set -eu

# End-to-end smoke launch for the packaged app.
#
# Runs the built executable with PI_WEB_DESKTOP_SMOKE=1: the app uses a
# temporary support directory ($TMPDIR/pi-web-desktop-smoke-<pid>), skips the
# single-instance lock and the service auto-start, loads the main window and
# prints the fixed marker below before exiting 0. The script never starts a real
# pi-web process and never writes the user's real Application Support directory;
# it only executes the app bundle it just built.
#
# Usage: ./Scripts/smoke.sh
#
# Environment:
#   PI_WEB_DESKTOP_SMOKE_TIMEOUT_SECONDS  wall-clock timeout, default 60 (integer > 0)
#
# Exit status: 0 when the app exits 0 and stdout/stderr contain the marker,
# 1 when the build, the exit status, the marker or the timeout check fails.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/Pi-Web-Desktop.app"
BIN="$APP/Contents/MacOS/PiWebDesktop"
MARKER='smoke: ready'
TIMEOUT_SECONDS=${PI_WEB_DESKTOP_SMOKE_TIMEOUT_SECONDS:-60}

case $TIMEOUT_SECONDS in
  ''|*[!0-9]*)
    printf 'error: PI_WEB_DESKTOP_SMOKE_TIMEOUT_SECONDS must be a positive integer, got "%s"\n' "$TIMEOUT_SECONDS" >&2
    exit 2
    ;;
  0)
    printf 'error: PI_WEB_DESKTOP_SMOKE_TIMEOUT_SECONDS must be greater than 0\n' >&2
    exit 2
    ;;
esac

if [ ! -x "$BIN" ]; then
  printf 'smoke: %s is missing, running ./Scripts/build.sh first\n' "$BIN"
  "$ROOT/Scripts/build.sh"
fi

if [ ! -x "$BIN" ]; then
  printf 'error: %s is still missing after ./Scripts/build.sh\n' "$BIN" >&2
  exit 1
fi

OUT=$(mktemp "${TMPDIR:-/tmp}/pi-web-desktop-smoke.XXXXXX") || {
  printf 'error: cannot create a temporary output file under %s\n' "${TMPDIR:-/tmp}" >&2
  exit 1
}
cleanup() {
  rm -f "$OUT"
}
trap cleanup EXIT HUP INT TERM

printf 'smoke: running %s with PI_WEB_DESKTOP_SMOKE=1 (timeout %ss)\n' "$BIN" "$TIMEOUT_SECONDS"
START=$(date +%s)
PI_WEB_DESKTOP_SMOKE=1 "$BIN" >"$OUT" 2>&1 &
SMOKE_PID=$!

# Watchdog: terminate the app when it exceeds the wall-clock budget. Waiting on
# the app itself keeps the exit status available and avoids polling for zombies.
( sleep "$TIMEOUT_SECONDS"; kill -TERM "$SMOKE_PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG_PID=$!

set +e
wait "$SMOKE_PID"
STATUS=$?
set -e
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true

ELAPSED=$(( $(date +%s) - START ))
printf 'smoke: app exit status %s after %ss\n' "$STATUS" "$ELAPSED"
printf '%s\n' '--- smoke output ---'
cat "$OUT"
printf '%s\n' '--- end smoke output ---'

if [ "$STATUS" -ne 0 ]; then
  if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
    printf 'error: smoke launch was terminated after the %ss timeout (exit status %s); the app never printed "%s" and exited 0\n' "$TIMEOUT_SECONDS" "$STATUS" "$MARKER" >&2
  else
    printf 'error: smoke launch exited with %s instead of 0\n' "$STATUS" >&2
  fi
  exit 1
fi

if ! grep -q -F "$MARKER" "$OUT"; then
  printf 'error: smoke output is missing the marker "%s"\n' "$MARKER" >&2
  exit 1
fi

printf 'smoke: OK (marker "%s", exit 0)\n' "$MARKER"
exit 0
