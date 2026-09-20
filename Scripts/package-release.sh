#!/bin/sh
set -eu

# Package an already built Pi Web Desktop bundle as the alpha release artifact.
# The same script is used locally and by .github/workflows/release.yml, so a
# rehearsal on a laptop exercises exactly the code path CI runs:
#
#   1. release tag / xcconfig version consistency  (Scripts/check-release-version.sh)
#   2. bundle identity and version                 (Scripts/check-identity.sh)
#   3. bundle content whitelist                    (only Contents/Info.plist,
#                                                   Contents/MacOS/**,
#                                                   Contents/Resources/** and
#                                                   Contents/_CodeSignature/**
#                                                   may ship)
#   4. ad-hoc signature verification               (codesign --verify --deep --strict)
#   5. signature and Gatekeeper evidence           (codesign -dv --verbose=4, spctl -a -vv)
#   6. fixed modification times, ZIP + SHA-256     (touch -t, ditto -c -k --norsrc --noextattr,
#                                                   shasum -a 256)
#   7. ZIP content cross-check, dist/release-metadata.env and the evidence section
#
# This script never runs xcodebuild and never signs anything. The bundle must
# already be ad-hoc signed by Scripts/build.sh (or Scripts/install.sh); a bundle
# with any other signature is refused, because the alpha release notes and the
# installation instructions document an ad-hoc, non-notarized build.
#
# Usage:
#   ./Scripts/package-release.sh [--app PATH] [--out DIR] [--tag TAG] [--build]
#   ./Scripts/package-release.sh --self-test
#
#   --app PATH   app bundle to package, default build/Pi-Web-Desktop.app
#   --out DIR    output directory, default dist/
#   --tag TAG    release tag forwarded to Scripts/check-release-version.sh;
#                without it that script reads GITHUB_REF_NAME, and with neither
#                the tag comparison is skipped (normal for a local rehearsal)
#   --build      run ./Scripts/build.sh first when the bundle is stale or absent
#   --self-test  run the whitelist and rejection cases in a temporary directory
#                outside the work tree, then exit without packaging anything
#
# release-metadata.env is `source`d by .github/workflows/release.yml, so every
# value this script writes into it is checked against a small character set
# first: VERSION and BUILD (from Info.plist), APP_STEM (from the app bundle
# name), SHA256 and COMMIT. A value that fails is refused with a readable error
# that names the allowed set and prints the value escaped, never raw, because
# the raw bytes are the untrusted part. APP_STEM is checked before the bundle is
# read and before --out is created, so a refused name cannot leave a dist/
# directory behind; the checks for SHA256 and COMMIT run where those values are
# produced. docs/releasing.md lists the whitelists and the audited values that
# deliberately have none.
#
# Outputs (in DIR), where the asset name carries the build number so a
# CFBundleVersion that drifted is visible in the release asset list:
#   <App>-<MARKETING_VERSION>+build.<BUILD>.zip           the release asset
#   <App>-<MARKETING_VERSION>+build.<BUILD>.zip.sha256    portable "hash  name" checksum file
#   <App>-<MARKETING_VERSION>+build.<BUILD>.evidence.md   signature/Gatekeeper evidence section
#   release-metadata.env                                  shell assignments sourced by the workflow
#
# Exit status: 0 packaged (or --self-test passed), 1 a check or packaging step
# failed (or a --self-test case failed), 2 usage error.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Absolute path of this script, so --self-test can run the real script again
# from its scratch directory.
SCRIPT_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")

usage() {
  printf 'usage: ./Scripts/package-release.sh [--app PATH] [--out DIR] [--tag TAG] [--build]\n'
  printf '       ./Scripts/package-release.sh --self-test\n'
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

# --- metadata whitelists -----------------------------------------------------

# Every value written into release-metadata.env is `source`d by
# .github/workflows/release.yml. Each one is checked against a small character
# set before it is written, so a crafted app bundle name or Info.plist value
# cannot change the meaning of that file (extra assignments, command
# substitution, forged log lines). The sets are deliberately narrower than
# "anything that is not a shell metacharacter": artifact names are a small
# value space, so an unusual name is refused instead of escaped.

# safe_value VALUE ALLOWED: render VALUE for a log line. Bytes inside ALLOWED
# (an awk bracket-expression body such as 0-9A-Za-z_-) are kept; every other
# byte becomes \xNN, so a value that failed its whitelist is reported with
# exactly the offending bytes escaped and suspicious content is never echoed
# raw, and a newline cannot forge a log line. The rendering is capped so an
# oversized argument cannot flood the log, and VALUE is terminated with a 0x01
# sentinel so a trailing newline or space is reported instead of being dropped.
safe_value() {
  printf '%s\001' "$1" | LC_ALL=C awk -v allowed="$2" '
    BEGIN {
      for (i = 0; i < 256; i++) hex[sprintf("%c", i)] = i
      keep = "^[" allowed "]$"
      sentinel = sprintf("%c", 1)
      limit = 80
    }
    {
      if (NR > 1) { out = out "\\x0a"; count = count + 4 }
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == sentinel) { done = 1; break }
        if (c ~ keep) piece = c
        else piece = sprintf("\\x%02x", hex[c])
        if (count + length(piece) > limit) { out = out "..."; exit }
        out = out piece
        count = count + length(piece)
      }
      if (done) exit
    }
    END { print out }
  '
}

# reject_value NAME VALUE ALLOWED_TEXT ALLOWED_SET: refuse a value whose
# whitelist check failed. The message names the whitelist and reports the value
# with the bytes outside ALLOWED_SET escaped; the raw bytes are never printed.
reject_value() {
  fail "$1 must be non-empty and use only $3; the value is written to release-metadata.env, which the release workflow sources. Escaped value (bytes outside the set as \\xNN): \"$(safe_value "$2" "$4")\""
}

# is_allowed_stem VALUE: 0 when VALUE is usable as an artifact name. A bundle
# name becomes APP_STEM, and APP_STEM becomes APP_NAME, ZIP_NAME and
# EVIDENCE_NAME in release-metadata.env, so this is the same whitelist idea as
# VERSION with a stricter set: `.` is not allowed because a bundle name never
# needs one and both artifact names add `.` only as their own suffix.
is_allowed_stem() {
  case $1 in
    ''|*[!0-9A-Za-z_-]*) return 1 ;;
  esac
  return 0
}

# --- bundle content whitelist ------------------------------------------------

# is_allowed_bundle_path RELATIVE_PATH: 0 when RELATIVE_PATH is one of the
# bundle members the release artifact may contain. Anything else fails the run
# and is listed, so an unexpected file (a stray README, a copied test fixture)
# cannot ship inside an otherwise correctly signed bundle. A `*` in a case
# pattern also matches `/`, so `Contents/Resources/*` covers
# Contents/Resources/** at any depth. Finder/AppleDouble metadata is refused
# even inside an allowed directory: `.DS_Store` and `._*` entries are exactly
# the detritus the xattr cleanup exists for.
is_allowed_bundle_path() {
  case $1 in
    ../*|*/../*|.DS_Store|*/.DS_Store|._*|*/._*) return 1 ;;
  esac
  case $1 in
    Contents|Contents/MacOS|Contents/Resources|Contents/_CodeSignature) return 0 ;;
    Contents/Info.plist) return 0 ;;
    Contents/MacOS/*|Contents/Resources/*|Contents/_CodeSignature/*) return 0 ;;
    *) return 1 ;;
  esac
}

# bundle_manifest APP: print every entry below APP, path-relative, LC_ALL=C
# sorted, one entry per line.
bundle_manifest() {
  bundle=$1
  ( cd "$bundle" && LC_ALL=C find . -mindepth 1 -print ) | LC_ALL=C sed 's|^\./||' | LC_ALL=C sort
}

# bundle_entry_count APP: count the entries below APP as records (NUL
# separated), not as lines. A path that contains a newline prints more lines
# than there are records, which check_bundle_contents refuses instead of
# trusting a manifest whose lines do not correspond to entries.
bundle_entry_count() {
  bundle=$1
  ( cd "$bundle" && LC_ALL=C find . -mindepth 1 -print0 ) | tr -cd '\0' | wc -c | tr -d '[:space:]'
}

# bundle_content_violations: read a manifest on stdin and print every entry the
# whitelist does not allow.
bundle_content_violations() {
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    is_allowed_bundle_path "$entry" || printf '%s\n' "$entry"
  done
}

# check_bundle_contents APP: set BUNDLE_MANIFEST and BUNDLE_ENTRY_COUNT and
# refuse the bundle when any entry is outside the whitelist. Called before
# --out is created, so a rejected bundle leaves no dist/ directory behind.
check_bundle_contents() {
  bundle=$1
  BUNDLE_MANIFEST=$(bundle_manifest "$bundle")
  records=$(bundle_entry_count "$bundle")
  lines=$(printf '%s\n' "$BUNDLE_MANIFEST" | wc -l | tr -d '[:space:]')
  BUNDLE_ENTRY_COUNT=$lines

  if [ "$records" != "$lines" ]; then
    fail "cannot validate the content of $bundle: the bundle has $records entries but $lines manifest lines, so at least one path contains a newline and cannot be listed reliably; rename that entry"
  fi

  violations=$(printf '%s\n' "$BUNDLE_MANIFEST" | bundle_content_violations)
  if [ -z "$violations" ]; then
    printf 'ok   bundle content matches the whitelist (%s entries)\n' "$BUNDLE_ENTRY_COUNT"
    return 0
  fi

  printf 'package-release: FAILED - the app bundle contains entries outside the release whitelist; only Contents/Info.plist, Contents/MacOS/**, Contents/Resources/** and Contents/_CodeSignature/** may ship\n' >&2
  printf '%s\n' "$violations" | while IFS= read -r entry; do
    printf '  not allowed: "%s"\n' "$(safe_value "$entry" '0-9A-Za-z._/-')" >&2
  done
  fail "$(printf '%s\n' "$violations" | wc -l | tr -d '[:space:]') bundle entry/entries are outside the whitelist (listed above); remove them from the bundle, or extend the whitelist in this script and docs/releasing.md deliberately"
}

# line_count TEXT: number of lines in TEXT, or 0 when TEXT is empty (a plain
# `wc -l` on an empty string reports 1 because of the newline printf adds).
line_count() {
  if [ -z "$1" ]; then
    printf '0\n'
  else
    printf '%s\n' "$1" | wc -l | tr -d '[:space:]'
  fi
}

# zip_failure_lines LABEL ENTRIES: print "LABEL: \"entry\"" for every non-empty
# line of ENTRIES. Entries are escaped so a crafted name cannot forge a line.
zip_failure_lines() {
  label=$1
  entries=$2
  [ -n "$entries" ] || return 0
  printf '%s\n' "$entries" | while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    printf '%s: "%s"\n' "$label" "$(safe_value "$entry" '0-9A-Za-z._/-')"
  done
}

# --- reproducible packaging --------------------------------------------------

# normalize_mtimes APP: give every entry the same modification time so the ZIP
# stores a fixed timestamp instead of the build time. The code signature seals
# file contents (CodeResources hashes), not mtimes, so this keeps
# codesign --verify --deep --strict passing; the packaging path verifies again
# after normalizing. SOURCE_DATE_EPOCH (digits only) overrides the default for
# reproducible-build tooling. Prints the timestamp it applied.
REPRO_MTIME=''
normalize_mtimes() {
  bundle=$1
  epoch=''
  case ${SOURCE_DATE_EPOCH:-} in
    ''|*[!0-9]*) ;;
    *) epoch=$SOURCE_DATE_EPOCH ;;
  esac
  if [ -n "$epoch" ]; then
    stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null) || fail "cannot convert SOURCE_DATE_EPOCH=$epoch into a timestamp with date -r"
  else
    stamp='200101010000.00'
  fi
  if ! find "$bundle" -exec touch -t "$stamp" {} +; then
    fail "cannot apply the fixed modification time $stamp to $bundle"
  fi
  REPRO_MTIME=$stamp
  if [ -n "$epoch" ]; then
    printf 'ok   every bundle entry carries the fixed modification time %s (SOURCE_DATE_EPOCH=%s)\n' "$stamp" "$epoch"
  else
    printf 'ok   every bundle entry carries the fixed modification time %s (default; SOURCE_DATE_EPOCH is not set)\n' "$stamp"
  fi
}

# --- self-test ---------------------------------------------------------------

# Scratch directory for --self-test. It is created outside $ROOT and removed
# again, also when a case fails; packaging never uses it.
TMP_DIR=
ZIP_SCRATCH=''
cleanup_temp_dir() {
  if [ -n "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
  if [ -n "$ZIP_SCRATCH" ]; then
    rm -rf "$ZIP_SCRATCH"
  fi
}
trap cleanup_temp_dir EXIT

# self_test_temp_dir: print the path of a fresh scratch directory outside $ROOT.
self_test_temp_dir() {
  base=${TMPDIR:-/tmp}
  if resolved=$(CDPATH= cd -- "$base" 2>/dev/null && pwd); then
    base=$resolved
  else
    base=/tmp
  fi
  case $base in
    "$ROOT"|"$ROOT"/*) base=/tmp ;;
  esac
  mktemp -d "$base/pi-web-desktop-package-release.XXXXXX"
}

# self_test_check_stem LABEL VALUE EXPECTED: EXPECTED is accept or reject.
self_test_check_stem() {
  label=$1
  value=$2
  expected=$3
  if is_allowed_stem "$value"; then
    actual=accept
  else
    actual=reject
  fi
  if [ "$actual" = "$expected" ]; then
    printf 'self-test: ok: %s -> %s\n' "$label" "$actual"
  else
    printf 'self-test: FAIL: %s -> %s, expected %s (escaped: "%s")\n' \
      "$label" "$actual" "$expected" "$(safe_value "$value" '0-9A-Za-z_-')" >&2
    failures=$((failures + 1))
  fi
}

# self_test_expect_reject LABEL APP_NAME ESCAPED: an existing bundle directory
# named APP_NAME inside the sandbox must be refused. The copied script must exit
# 1, name the allowed set, print the ESCAPED form, never echo the raw stem, and
# leave the sandbox's default dist/ directory absent.
self_test_expect_reject() {
  label=$1
  app_name=$2
  escaped=$3
  app="$TMP_DIR/repo/$app_name"
  stem=${app_name%.app}
  mkdir -p "$app"
  status=0
  output=$("$TMP_DIR/repo/Scripts/package-release.sh" --app "$app" 2>&1) || status=$?
  rm -rf "$app"

  ok=1
  case $status in
    1) ;;
    *)
      printf 'self-test: FAIL: %s exited %s instead of 1\n' "$label" "$status" >&2
      ok=0
      ;;
  esac
  case $output in
    *'0-9A-Za-z_-'*) ;;
    *)
      printf 'self-test: FAIL: %s does not name the allowed character set\n' "$label" >&2
      ok=0
      ;;
  esac
  case $output in
    *"$escaped"*) ;;
    *)
      printf 'self-test: FAIL: %s does not print the escaped value %s\n' "$label" "$escaped" >&2
      ok=0
      ;;
  esac
  case $output in
    *"$stem"*)
      printf 'self-test: FAIL: %s echoed the raw bundle name\n' "$label" >&2
      ok=0
      ;;
  esac
  if [ -e "$TMP_DIR/repo/dist" ]; then
    printf 'self-test: FAIL: %s created %s/dist\n' "$label" "$TMP_DIR/repo" >&2
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    printf 'self-test: ok: %s is rejected before anything is written\n' "$label"
  else
    failures=$((failures + 1))
  fi
}

# self_test_expect_gate_pass LABEL APP_NAME: a whitelisted name must get past
# the stem check and stop at the next gate instead (the sandbox bundle has no
# Info.plist), which proves the whitelist is not what rejected it, and still
# must not create dist/.
self_test_expect_gate_pass() {
  label=$1
  app_name=$2
  app="$TMP_DIR/repo/$app_name"
  mkdir -p "$app"
  status=0
  output=$("$TMP_DIR/repo/Scripts/package-release.sh" --app "$app" 2>&1) || status=$?
  rm -rf "$app"

  ok=1
  case $status in
    1) ;;
    *)
      printf 'self-test: FAIL: %s exited %s instead of 1\n' "$label" "$status" >&2
      ok=0
      ;;
  esac
  case $output in
    *Contents/Info.plist*) ;;
    *)
      printf 'self-test: FAIL: %s did not stop at the missing Info.plist check\n' "$label" >&2
      ok=0
      ;;
  esac
  case $output in
    *'0-9A-Za-z_-'*)
      printf 'self-test: FAIL: %s was refused by the stem whitelist\n' "$label" >&2
      ok=0
      ;;
  esac
  if [ -e "$TMP_DIR/repo/dist" ]; then
    printf 'self-test: FAIL: %s created %s/dist\n' "$label" "$TMP_DIR/repo" >&2
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    printf 'self-test: ok: %s passes the whitelist and reaches the next check\n' "$label"
  else
    failures=$((failures + 1))
  fi
}

# self_test_check_path LABEL PATH EXPECTED: the bundle content whitelist table.
self_test_check_path() {
  label=$1
  value=$2
  expected=$3
  if is_allowed_bundle_path "$value"; then
    actual=accept
  else
    actual=reject
  fi
  if [ "$actual" = "$expected" ]; then
    printf 'self-test: ok: %s -> %s\n' "$label" "$actual"
  else
    printf 'self-test: FAIL: %s -> %s, expected %s (escaped: "%s")\n' \
      "$label" "$actual" "$expected" "$(safe_value "$value" '0-9A-Za-z._/-')" >&2
    failures=$((failures + 1))
  fi
}

# self_test_bundle_with APP_NAME STRAY_REL: build a fixture bundle inside the
# sandbox with a valid Info.plist and the whitelisted members, plus STRAY_REL
# when it is not empty. Prints the bundle path.
self_test_bundle_with() {
  app_name=$1
  stray_rel=$2
  app="$TMP_DIR/repo/$app_name"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/_CodeSignature"
  printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/Fixture"
  chmod +x "$app/Contents/MacOS/Fixture"
  printf 'fixture icon\n' > "$app/Contents/Resources/Fixture.icns"
  printf 'fixture seal\n' > "$app/Contents/_CodeSignature/CodeResources"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>9.9.9-alpha.7</string>
    <key>CFBundleVersion</key>
    <string>7</string>
</dict>
</plist>
PLIST
  if [ -n "$stray_rel" ]; then
    mkdir -p "$app/$(dirname -- "$stray_rel")"
    printf 'stray\n' > "$app/$stray_rel"
  fi
  printf '%s\n' "$app"
}

# self_test_content_wiring: the copied script must name a stray bundle entry and
# refuse the bundle without creating dist/; a fixture bundle that only contains
# whitelisted entries must get past the content check and reach the next gate.
self_test_content_wiring() {
  app=$(self_test_bundle_with 'Fixture.app' 'Contents/stray.txt')
  status=0
  output=$("$TMP_DIR/repo/Scripts/package-release.sh" --app "$app" 2>&1) || status=$?

  ok=1
  case $status in
    1) ;;
    *)
      printf 'self-test: FAIL: a stray bundle entry exited %s instead of 1\n' "$status" >&2
      ok=0
      ;;
  esac
  case $output in
    *'Contents/stray.txt'*) ;;
    *)
      printf 'self-test: FAIL: the stray bundle entry is not listed in the rejection\n' >&2
      ok=0
      ;;
  esac
  case $output in
    *whitelist*) ;;
    *)
      printf 'self-test: FAIL: the content rejection does not name the whitelist\n' >&2
      ok=0
      ;;
  esac
  if [ -e "$TMP_DIR/repo/dist" ]; then
    printf 'self-test: FAIL: a stray bundle entry created %s/dist\n' "$TMP_DIR/repo" >&2
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    printf 'self-test: ok: a stray bundle entry is listed and refused before anything is written\n'
  else
    failures=$((failures + 1))
  fi

  # Whitelisted-only fixture: it must print the accepted content check and reach
  # the release version gate, which fails here because the sandbox copy has no
  # Scripts/check-release-version.sh.
  app=$(self_test_bundle_with 'Fixture.app' '')
  status=0
  output=$("$TMP_DIR/repo/Scripts/package-release.sh" --app "$app" 2>&1) || status=$?
  rm -rf "$app" "$TMP_DIR/repo/dist"

  ok=1
  case $output in
    *'bundle content matches the whitelist'*) ;;
    *)
      printf 'self-test: FAIL: a whitelisted fixture bundle was not accepted by the content check\n' >&2
      ok=0
      ;;
  esac
  case $output in
    *'== release version =='*) ;;
    *)
      printf 'self-test: FAIL: a whitelisted fixture bundle did not reach the release version gate\n' >&2
      ok=0
      ;;
  esac
  case $status in
    1) ;;
    *)
      printf 'self-test: FAIL: a whitelisted fixture bundle exited %s instead of stopping at the next gate with 1\n' "$status" >&2
      ok=0
      ;;
  esac
  if [ "$ok" -eq 1 ]; then
    printf 'self-test: ok: a whitelisted fixture bundle passes the content check and reaches the version gate\n'
  else
    failures=$((failures + 1))
  fi

  # A path with a newline cannot be listed reliably, so the record/line count
  # mismatch must be detected instead of letting a two-line manifest pass the
  # whitelist entry by entry.
  app=$(self_test_bundle_with 'Fixture.app' '')
  odd_name=$(printf 'Contents/Resources/a\nb')
  printf 'odd\n' > "$app/$odd_name"
  status=0
  output=$("$TMP_DIR/repo/Scripts/package-release.sh" --app "$app" 2>&1) || status=$?
  rm -rf "$app" "$TMP_DIR/repo/dist"

  ok=1
  case $status in
    1) ;;
    *)
      printf 'self-test: FAIL: an entry name with a newline exited %s instead of 1\n' "$status" >&2
      ok=0
      ;;
  esac
  case $output in
    *'manifest lines'*) ;;
    *)
      printf 'self-test: FAIL: an entry name with a newline was not reported as a manifest record/line mismatch\n' >&2
      ok=0
      ;;
  esac
  if [ "$ok" -eq 1 ]; then
    printf 'self-test: ok: an entry name with a newline is refused as an unlistable manifest\n'
  else
    failures=$((failures + 1))
  fi
}

# self_test_full_package: positive end-to-end case with the real bundle. It is
# skipped, not failed, when the bundle is absent or when the work tree has
# untracked files, because the packaging path runs Scripts/check-identity.sh,
# which refuses an unscanned work tree (security review R-11).
self_test_full_package() {
  app="$ROOT/build/Pi-Web-Desktop.app"
  if [ ! -d "$app" ]; then
    printf 'self-test: skip: %s is absent, so the positive end-to-end case needs ./Scripts/build.sh first\n' "$app"
    return 0
  fi
  if [ -n "$(git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)" ]; then
    printf 'self-test: skip: the work tree has untracked files, which Scripts/check-identity.sh refuses (security review R-11); stage them and rerun for the positive end-to-end case\n'
    return 0
  fi

  out="$TMP_DIR/full-package"
  status=0
  output=$("$SCRIPT_PATH" --app "$app" --out "$out" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'self-test: FAIL: packaging a whitelisted bundle name failed with status %s (last 20 lines):\n' "$status" >&2
    printf '%s\n' "$output" | tail -n 20 >&2
    failures=$((failures + 1))
    return 0
  fi

  # The workflow `source`s this file, so source it here the same way: the
  # whitelist is what keeps that operation predictable.
  if ( set -eu
       . "$out/release-metadata.env"
       [ -n "$VERSION" ] && [ -n "$APP_NAME" ] && [ -f "$out/$ZIP_NAME" ] \
         && [ -f "$out/$ZIP_NAME.sha256" ] && [ -f "$out/$EVIDENCE_NAME" ]
     ); then
    zip_name=$(sed -n 's/^ZIP_NAME=//p' "$out/release-metadata.env")
    evidence_name=$(sed -n 's/^EVIDENCE_NAME=//p' "$out/release-metadata.env")
    build=$(sed -n 's/^BUILD=//p' "$out/release-metadata.env")
    printf 'self-test: ok: a whitelisted bundle name packaged end to end and release-metadata.env sources cleanly (%s, %s)\n' "$zip_name" "$evidence_name"
    # The asset name must carry the build number (code review W4 / L6), so the
    # release listing shows which CFBundleVersion a download contains.
    case $zip_name in
      *"+build.$build.zip") ;;
      *)
        printf 'self-test: FAIL: ZIP_NAME=%s does not carry the +build.%s.zip suffix\n' "$zip_name" "$build" >&2
        failures=$((failures + 1))
        ;;
    esac
    case $evidence_name in
      *"+build.$build.evidence.md") ;;
      *)
        printf 'self-test: FAIL: EVIDENCE_NAME=%s does not carry the +build.%s suffix\n' "$evidence_name" "$build" >&2
        failures=$((failures + 1))
        ;;
    esac
  else
    printf 'self-test: FAIL: %s is missing, or sourcing it does not yield VERSION/APP_NAME/ZIP_NAME/EVIDENCE_NAME with matching files\n' "$out/release-metadata.env" >&2
    failures=$((failures + 1))
  fi
  return 0
}

# self_test_real_bundle_stray: copy the real bundle, add one file that the
# whitelist does not allow, and require the script to refuse it by name before
# any ZIP exists. Skipped, not failed, when the bundle is absent.
self_test_real_bundle_stray() {
  app="$ROOT/build/Pi-Web-Desktop.app"
  if [ ! -d "$app" ]; then
    printf 'self-test: skip: %s is absent, so the stray-entry case needs ./Scripts/build.sh first\n' "$app"
    return 0
  fi

  copy="$TMP_DIR/stray/Pi-Web-Desktop.app"
  rm -rf "$TMP_DIR/stray" "$TMP_DIR/stray-out"
  mkdir -p "$TMP_DIR/stray"
  if ! ditto "$app" "$copy" >/dev/null 2>&1; then
    printf 'self-test: FAIL: cannot copy %s into %s\n' "$app" "$TMP_DIR/stray" >&2
    failures=$((failures + 1))
    return 0
  fi
  printf 'stray\n' > "$copy/Contents/stray.txt"

  status=0
  output=$("$SCRIPT_PATH" --app "$copy" --out "$TMP_DIR/stray-out" 2>&1) || status=$?

  ok=1
  case $status in
    1) ;;
    *)
      printf 'self-test: FAIL: the real bundle with a stray entry exited %s instead of 1\n' "$status" >&2
      ok=0
      ;;
  esac
  case $output in
    *'Contents/stray.txt'*) ;;
    *)
      printf 'self-test: FAIL: the stray entry of the real bundle is not listed in the rejection\n' >&2
      ok=0
      ;;
  esac
  if [ -e "$TMP_DIR/stray-out" ]; then
    printf 'self-test: FAIL: the real bundle with a stray entry created %s\n' "$TMP_DIR/stray-out" >&2
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    printf 'self-test: ok: the real bundle with an extra entry is refused by name and writes nothing\n'
  else
    failures=$((failures + 1))
  fi
  return 0
}

self_test() {
  failures=0

  # The self-test must not touch the work tree: the script is copied into a
  # temporary directory outside $ROOT, the copy resolves ROOT there, and its
  # default --out is a throwaway <tmp>/repo/dist that must stay absent.
  TMP_DIR=$(self_test_temp_dir) || return 1
  case $TMP_DIR in
    "$ROOT"|"$ROOT"/*)
      printf 'self-test: FAIL: scratch directory %s is inside the repository\n' "$TMP_DIR" >&2
      return 1
      ;;
  esac
  mkdir -p "$TMP_DIR/repo/Scripts"
  if ! cp "$SCRIPT_PATH" "$TMP_DIR/repo/Scripts/package-release.sh"; then
    printf 'self-test: FAIL: cannot copy %s into %s\n' "$SCRIPT_PATH" "$TMP_DIR" >&2
    return 1
  fi
  chmod +x "$TMP_DIR/repo/Scripts/package-release.sh"

  printf 'self-test: whitelist table\n'
  self_test_check_stem 'representative bundle name' 'Pi-Web-Desktop' accept
  self_test_check_stem 'digits, underscore and hyphen' 'Pi_Web_1-2' accept
  self_test_check_stem 'single character' 'A' accept
  self_test_check_stem 'empty name' '' reject
  self_test_check_stem 'space' 'Pi Web' reject
  self_test_check_stem 'semicolon' 'Pi;Web' reject
  self_test_check_stem 'command substitution' 'Pi$(id)Web' reject
  self_test_check_stem 'backticks' 'Pi`id`Web' reject
  self_test_check_stem 'single quote' "Pi'Web" reject
  self_test_check_stem 'double quote' 'Pi"Web' reject
  self_test_check_stem 'glob character' 'Pi*Web' reject
  self_test_check_stem 'dot (stricter than VERSION on purpose)' 'Pi.Web' reject
  self_test_check_stem 'path separator' 'Pi/Web' reject
  self_test_check_stem 'newline' "$(printf 'Pi\nWeb')" reject
  self_test_check_stem 'non-ASCII bytes' "$(printf 'Pi\347\211\210')" reject

  printf 'self-test: rejection path (copied script, scratch dist/)\n'
  self_test_expect_reject 'space in the bundle name' 'pi web.app' '\x20'
  self_test_expect_reject 'semicolon in the bundle name' 'pi;web.app' '\x3b'
  self_test_expect_reject 'command substitution in the bundle name' 'pi$(id).app' '\x24'
  self_test_expect_reject 'backticks in the bundle name' 'pi`id`.app' '\x60'
  self_test_expect_reject 'single quote in the bundle name' "pi'web.app" '\x27'
  self_test_expect_reject 'newline in the bundle name' "$(printf 'pi\nweb.app')" '\x0a'
  self_test_expect_reject 'dot in the bundle name' 'pi.web.app' '\x2e'
  self_test_expect_reject 'non-ASCII bytes in the bundle name' "$(printf 'pi\347\211\210.app')" '\xe7'

  printf 'self-test: legal names\n'
  self_test_expect_gate_pass 'default-looking bundle name' 'Pi-Web-Desktop.app'
  self_test_expect_gate_pass 'letters, digits, underscore and hyphen' 'Pi_Web_1-2.app'

  printf 'self-test: bundle content whitelist table\n'
  self_test_check_path 'bundle root' 'Contents' accept
  self_test_check_path 'MacOS directory' 'Contents/MacOS' accept
  self_test_check_path 'the executable' 'Contents/MacOS/PiWebDesktop' accept
  self_test_check_path 'Info.plist' 'Contents/Info.plist' accept
  self_test_check_path 'Resources directory' 'Contents/Resources' accept
  self_test_check_path 'resource in a nested directory' 'Contents/Resources/zh-Hans.lproj/Localizable.strings' accept
  self_test_check_path 'signature seal' 'Contents/_CodeSignature/CodeResources' accept
  self_test_check_path 'extra file at the bundle root' '.DS_Store' reject
  self_test_check_path 'extra file next to Info.plist' 'Contents/README.txt' reject
  self_test_check_path 'Frameworks directory' 'Contents/Frameworks/Foo.framework/Foo' reject
  self_test_check_path 'path that climbs out of Resources' 'Contents/Resources/../stray.txt' reject
  self_test_check_path 'Finder metadata in MacOS' 'Contents/MacOS/.DS_Store' reject
  self_test_check_path 'AppleDouble entry in Resources' 'Contents/Resources/._Icon.icns' reject

  printf 'self-test: bundle content wiring (copied script, scratch dist/)\n'
  self_test_content_wiring

  printf 'self-test: positive end-to-end case\n'
  self_test_full_package

  printf 'self-test: real bundle with a stray entry\n'
  self_test_real_bundle_stray

  if [ "$failures" -ne 0 ]; then
    printf 'self-test: FAILED (%s failure(s))\n' "$failures" >&2
    return 1
  fi
  printf 'self-test: PASS (stem whitelist table, rejection path without dist/, legal names, content whitelist table and wiring, positive end-to-end case with +build names, scratch directory cleaned up)\n'
  return 0
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
SELF_TEST=0

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
    --self-test)
      SELF_TEST=1
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

if [ "$SELF_TEST" -eq 1 ]; then
  if [ -n "$APP" ] || [ -n "$OUT" ] || [ -n "$TAG" ] || [ "$BUILD_FIRST" -eq 1 ]; then
    usage_error '--self-test does not take --app, --out, --tag or --build'
  fi
  if self_test; then
    exit 0
  fi
  exit 1
fi

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
APP_STEM=${APP_BASENAME%.app}

# Validate the artifact name before the bundle is read and before --out is
# created, so a refused name cannot leave a dist/ directory behind (--self-test
# asserts exactly that). APP_STEM reaches APP_NAME, ZIP_NAME and EVIDENCE_NAME
# in release-metadata.env and the evidence section of the release notes.
is_allowed_stem "$APP_STEM" || reject_value 'the app bundle name (--app basename minus .app, i.e. APP_STEM)' "$APP_STEM" 'ASCII letters, digits, hyphen and underscore (0-9A-Za-z_-)' '0-9A-Za-z_-'

PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || fail "missing $PLIST"

if ! VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST" 2>/dev/null); then
  fail "cannot read CFBundleShortVersionString from $PLIST"
fi
if ! BUILD=$(plutil -extract CFBundleVersion raw -o - "$PLIST" 2>/dev/null); then
  fail "cannot read CFBundleVersion from $PLIST"
fi

# release-metadata.env is sourced by the workflow, so keep the value space small
# and reject anything that could turn into a surprising assignment. The value is
# reported escaped, not raw: the plist bytes are what is not trusted.
case $VERSION in
  ''|*[!0-9A-Za-z._+-]*) reject_value 'CFBundleShortVersionString' "$VERSION" 'the characters 0-9A-Za-z._+-' '0-9A-Za-z._+-' ;;
esac
case $BUILD in
  ''|*[!0-9A-Za-z._+-]*) reject_value 'CFBundleVersion' "$BUILD" 'the characters 0-9A-Za-z._+-' '0-9A-Za-z._+-' ;;
esac
# The build number is part of the asset name, and the tag/build rule in
# docs/releasing.md (enforced by Scripts/check-release-version.sh) only accepts
# a decimal counter, so a bundle whose CFBundleVersion is not one is refused
# here instead of producing an asset name nobody can map back to a tag.
case $BUILD in
  ''|*[!0-9]*) reject_value 'CFBundleVersion' "$BUILD" 'a plain decimal build number (0-9), as required by the tag/build rule in docs/releasing.md' '0-9' ;;
esac

# The content whitelist runs before --out is created, so a bundle that fails it
# leaves no dist/ directory behind.
printf '\n== bundle content whitelist ==\n'
check_bundle_contents "$APP"

ZIP_NAME="$APP_STEM-$VERSION+build.$BUILD.zip"
EVIDENCE_NAME="$APP_STEM-$VERSION+build.$BUILD.evidence.md"

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
# Keep Finder/File Provider metadata out of the ZIP: ditto would otherwise store
# it in __MACOSX/ AppleDouble entries and restore it on the user's machine.
# --norsrc --noextattr writes an archive that contains only the whitelisted
# bundle content, which the cross-check below relies on. The bundle was already
# verified above and cleaning xattrs does not touch the code signature.
clear_extended_attributes "$APP"

# Fixed modification times: the ZIP stores a per-entry timestamp, so without
# this the container records the build time and two packagings of the same
# bundle differ. The code signature seals file contents (CodeResources hashes),
# not mtimes; verify again so the state that gets packed is the state the
# evidence describes.
printf '\n== reproducible timestamps ==\n'
normalize_mtimes "$APP"
set +e
MTIME_VERIFY_OUTPUT=$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)
MTIME_VERIFY_STATUS=$?
set -e
if [ "$MTIME_VERIFY_STATUS" -ne 0 ]; then
  [ -z "$MTIME_VERIFY_OUTPUT" ] || printf '%s\n' "$MTIME_VERIFY_OUTPUT" >&2
  fail "codesign --verify --deep --strict failed with status $MTIME_VERIFY_STATUS after the fixed modification times were applied"
fi
printf 'ok   codesign --verify --deep --strict still passes after normalizing modification times\n'

( cd "$APP_PARENT" && ditto -c -k --norsrc --noextattr --keepParent "$APP_BASENAME" "$OUT/$ZIP_NAME" )
( cd "$OUT" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256" )
SHA256=$(awk '{print $1}' "$OUT/$ZIP_NAME.sha256")
[ -n "$SHA256" ] || fail "cannot read the SHA-256 of $ZIP_NAME"
# The digest goes into release-metadata.env as well, so check the shape the
# checksum tool is expected to produce before trusting its output.
case $SHA256 in
  *[!0-9a-f]*) reject_value 'SHA256' "$SHA256" '64 lowercase hexadecimal characters (0-9a-f)' '0-9a-f' ;;
esac
[ "${#SHA256}" -eq 64 ] || reject_value 'SHA256' "$SHA256" '64 lowercase hexadecimal characters (0-9a-f)' '0-9a-f'

# Verify the checksum file with the same command the release notes give users.
( cd "$OUT" && shasum -a 256 -c "$ZIP_NAME.sha256" )

# Cross-check the archive itself against the manifest computed before --out
# existed: every ZIP entry must be the bundle root, a whitelisted member of it,
# or nothing at all (ditto with --norsrc --noextattr adds no __MACOSX/
# AppleDouble entries). This catches what the archiver added or dropped after
# the bundle whitelist check.
ZIP_CROSS_CHECK='skipped: unzip is not available'
if command -v unzip >/dev/null 2>&1; then
  ZIP_LIST=$(unzip -Z1 "$OUT/$ZIP_NAME") || fail "cannot list $OUT/$ZIP_NAME with unzip -Z1"
  ZIP_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/pi-web-desktop-zipcheck.XXXXXX") || fail "cannot create a scratch directory for the ZIP cross-check"
  printf '%s\n' "$BUNDLE_MANIFEST" > "$ZIP_SCRATCH/manifest"
  # Only entries inside the bundle reach the manifest comparison; whatever is
  # left (an AppleDouble tree, a foreign top-level name) is reported by
  # ZIP_OUTSIDE alone instead of appearing twice. index() keeps the prefix match
  # anchored: grep -F would also match a name that merely contains it.
  printf '%s\n' "$ZIP_LIST" | LC_ALL=C awk -v prefix="$APP_BASENAME/" '
      index($0, prefix) == 1 {
        rel = substr($0, length(prefix) + 1)
        sub(/\/$/, "", rel)
        if (rel != "") print rel
      }
    ' | LC_ALL=C sort > "$ZIP_SCRATCH/zip"
  # No `case` inside this $( ... ) substitution: bash 3.2 (macOS /bin/sh)
  # ends a substitution at the first unquoted `)`, and every case pattern
  # contains one. The prefix test below uses parameter expansion instead.
  ZIP_OUTSIDE=$(printf '%s\n' "$ZIP_LIST" | while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      if [ "$entry" = "$APP_BASENAME" ]; then
        continue
      fi
      if [ "${entry#"$APP_BASENAME"/}" != "$entry" ]; then
        continue
      fi
      printf '%s\n' "$entry"
    done)
  ZIP_EXTRA=$(LC_ALL=C comm -13 "$ZIP_SCRATCH/manifest" "$ZIP_SCRATCH/zip")
  ZIP_MISSING=$(LC_ALL=C comm -23 "$ZIP_SCRATCH/manifest" "$ZIP_SCRATCH/zip")
  ZIP_OUTSIDE_COUNT=$(line_count "$ZIP_OUTSIDE")
  ZIP_EXTRA_COUNT=$(line_count "$ZIP_EXTRA")
  ZIP_MISSING_COUNT=$(line_count "$ZIP_MISSING")
  ZIP_PROBLEMS=$((ZIP_OUTSIDE_COUNT + ZIP_EXTRA_COUNT + ZIP_MISSING_COUNT))
  if [ "$ZIP_PROBLEMS" -ne 0 ]; then
    printf 'package-release: FAILED - %s does not match the whitelisted bundle content:\n' "$ZIP_NAME" >&2
    zip_failure_lines 'entry outside the bundle' "$ZIP_OUTSIDE" >&2
    zip_failure_lines 'entry not in the bundle' "$ZIP_EXTRA" >&2
    zip_failure_lines 'bundle entry missing from the ZIP' "$ZIP_MISSING" >&2
    fail "$ZIP_PROBLEMS ZIP entry/entries do not match the bundle manifest listed above; the archive is not the whitelisted bundle, so it is not released"
  fi
  ZIP_CROSS_CHECK="ok: $ZIP_NAME contains exactly the $BUNDLE_ENTRY_COUNT whitelisted bundle entries"
  printf 'ok   %s contains exactly the %s whitelisted bundle entries (no __MACOSX/ entries)\n' "$ZIP_NAME" "$BUNDLE_ENTRY_COUNT"
else
  printf 'info unzip is not available, so the ZIP content cross-check is skipped (the bundle whitelist check above still ran)\n'
fi

COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)
[ -n "$COMMIT" ] || COMMIT=unknown
case $COMMIT in
  unknown) ;;
  *[!0-9a-f]*) reject_value 'COMMIT' "$COMMIT" 'a lowercase hexadecimal git object name or "unknown" (0-9a-f)' '0-9a-f' ;;
esac
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
  printf '%s\n' "- 包内容：${BUNDLE_ENTRY_COUNT} 个条目，全部命中发布白名单（Contents/Info.plist、Contents/MacOS/**、Contents/Resources/**、Contents/_CodeSignature/**）；ZIP 复验：${ZIP_CROSS_CHECK}。"
  printf '%s\n' "- 可复现性措施：包内每条目 mtime 固定为 ${REPRO_MTIME}（SOURCE_DATE_EPOCH 可覆盖）；ZIP 用 ditto -c -k --norsrc --noextattr 从该包生成，不含 __MACOSX/ 或扩展属性条目；清单按 LC_ALL=C 排序。"
  printf '%s\n' '- 已知不可复现的字节：Contents/MacOS/PiWebDesktop（编译器与链接器版本、构建路径等），Contents/_CodeSignature/CodeResources 与签名 blob（ad-hoc CDHash 随内容与签名调用变化），以及 ZIP 容器自身的头/尾元数据（ditto 版本与条目顺序）。同一提交重新构建会得到不同的 SHA-256；下面的 SHA-256 只记录这一个具体产物。'
  printf '\n<details>\n<summary>包内容清单（%s 个条目；SHA-256 为包内文件内容摘要）</summary>\n\n```text\n' "$BUNDLE_ENTRY_COUNT"
  ( cd "$APP" && LC_ALL=C find . -mindepth 1 -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | LC_ALL=C sed 's|  \./|  |' )
  printf '```\n\n</details>\n'
  printf '%s\n' '- 签名类型：**adhoc**。codesign 报告 "Signature=adhoc" 与 "TeamIdentifier=not set"：没有 Developer ID 证书，也不是经过 Apple 公证的发行版。'
  printf '%s\n' '- Apple 公证：**未公证**。本项目没有 Apple Developer 账号，发布流程不执行公证。'
  printf '%s\n' "- \"codesign --verify --deep --strict\"：退出码 ${VERIFY_STATUS}（通过），签名与资源封条未损坏；固定 mtime 后再校验一次（退出码 ${MTIME_VERIFY_STATUS}）。"
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
