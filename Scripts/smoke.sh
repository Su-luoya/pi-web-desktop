#!/bin/sh
set -eu

# End-to-end smoke launches for the packaged app.
#
# Runs the built executable in two mutually independent modes:
#
#   1. startup mode:     PI_WEB_DESKTOP_SMOKE=1
#   2. diagnostics mode: PI_WEB_DESKTOP_SMOKE=diagnostics
#
# Both modes use a temporary support directory
# ($TMPDIR/pi-web-desktop-smoke-<pid>), skip the single-instance lock and the
# service auto-start, never start a real pi-web process and never write the
# user's real Application Support directory or UserDefaults. Startup mode
# builds the main window and prints "smoke: ready"; diagnostics mode runs the
# deterministic diagnostics fixture through the real routing decision, opens
# the diagnostics status page and prints "smoke: diagnostics ready". Both must
# exit 0. The script only executes the app bundle it just built.
#
# Usage: ./Scripts/smoke.sh
#
# Environment:
#   PI_WEB_DESKTOP_SMOKE_TIMEOUT_SECONDS  per-mode wall-clock timeout, default 60 (integer > 0)
#
# Exit status: 0 when both modes exit 0 and stdout/stderr contain their marker,
# 1 when the build, an exit status, a marker or a timeout check fails.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/Pi-Web-Desktop.app"
BIN="$APP/Contents/MacOS/PiWebDesktop"
STARTUP_MARKER='smoke: ready'
DIAGNOSTICS_MARKER='smoke: diagnostics ready'
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

# PIDs are cleared again once their process has been reaped, so the cleanup trap
# never signals a PID that the system could have reused.
SMOKE_PID=''
WATCHDOG_PID=''
cleanup() {
  if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
  fi
  if [ -n "$SMOKE_PID" ]; then
    kill "$SMOKE_PID" 2>/dev/null || true
  fi
  rm -f "$OUT"
}
trap cleanup EXIT HUP INT TERM

# $1 = PI_WEB_DESKTOP_SMOKE value, $2 = required marker, $3 = mode label.
# Returns 0 only when the app exits 0 within the timeout and the captured
# output contains the marker.
run_smoke_mode() {
  mode_value=$1
  mode_marker=$2
  mode_label=$3

  printf 'smoke: running %s with PI_WEB_DESKTOP_SMOKE=%s (%s mode, timeout %ss)\n' "$BIN" "$mode_value" "$mode_label" "$TIMEOUT_SECONDS"
  START=$(date +%s)
  PI_WEB_DESKTOP_SMOKE=$mode_value "$BIN" >"$OUT" 2>&1 &
  SMOKE_PID=$!

  # Watchdog: terminate the app when it exceeds the wall-clock budget. Waiting
  # on the app itself keeps the exit status available and avoids polling for
  # zombies.
  #
  # The watchdog subshell sleeps as a child it can kill again: when this script
  # kills the subshell, the trap below kills the sleep too. `sleep` directly in
  # the subshell would be orphaned on every run (code review W4 / L2: two
  # `sleep 60` processes were left behind after one smoke run) because killing
  # the subshell does not signal its child.
  (
    watchdog_sleep_pid=''
    stop_watchdog_sleep() {
      if [ -n "$watchdog_sleep_pid" ]; then
        kill "$watchdog_sleep_pid" 2>/dev/null || true
        wait "$watchdog_sleep_pid" 2>/dev/null || true
      fi
    }
    trap stop_watchdog_sleep EXIT HUP INT TERM
    sleep "$TIMEOUT_SECONDS" &
    watchdog_sleep_pid=$!
    wait "$watchdog_sleep_pid" 2>/dev/null || exit 0
    kill -TERM "$SMOKE_PID" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  WATCHDOG_PID=$!

  set +e
  wait "$SMOKE_PID"
  STATUS=$?
  set -e
  SMOKE_PID=''
  kill "$WATCHDOG_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  WATCHDOG_PID=''

  ELAPSED=$(( $(date +%s) - START ))
  printf 'smoke: %s mode app exit status %s after %ss\n' "$mode_label" "$STATUS" "$ELAPSED"
  printf '%s\n' "--- smoke output ($mode_label mode) ---"
  cat "$OUT"
  printf '%s\n' "--- end smoke output ($mode_label mode) ---"

  if [ "$STATUS" -ne 0 ]; then
    if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
      printf 'error: %s mode was terminated after the %ss timeout (exit status %s); the app never printed "%s" and exited 0\n' "$mode_label" "$TIMEOUT_SECONDS" "$STATUS" "$mode_marker" >&2
    else
      printf 'error: %s mode exited with %s instead of 0\n' "$mode_label" "$STATUS" >&2
    fi
    return 1
  fi

  if ! grep -q -F "$mode_marker" "$OUT"; then
    printf 'error: %s mode output is missing the marker "%s"\n' "$mode_label" "$mode_marker" >&2
    return 1
  fi

  printf 'smoke: %s mode OK (marker "%s", exit 0)\n' "$mode_label" "$mode_marker"
  return 0
}

FAILURES=0
run_smoke_mode 1 "$STARTUP_MARKER" startup || FAILURES=1
run_smoke_mode diagnostics "$DIAGNOSTICS_MARKER" diagnostics || FAILURES=1

if [ "$FAILURES" -ne 0 ]; then
  printf 'error: smoke failed; both modes must exit 0 and print their marker ("%s", "%s")\n' "$STARTUP_MARKER" "$DIAGNOSTICS_MARKER" >&2
  exit 1
fi

printf 'smoke: OK (markers "%s" and "%s", both modes exit 0)\n' "$STARTUP_MARKER" "$DIAGNOSTICS_MARKER"
exit 0
