#!/bin/sh
set -eu

# Assert that Pi Web Desktop identity and version have exactly one source
# (Configuration/AppIdentity.xcconfig) and that the Xcode project, the packaging
# script, the built app bundle and the service defaults all agree with it.
#
# Usage: ./Scripts/check-identity.sh [path/to/Pi-Web-Desktop.app]
#
# Exit status: 0 when every check passes, 1 when at least one check fails.
#
# The repository text scan below never reports this file itself: the file is
# excluded from the scan, and every pattern is assembled from fragments so the
# script text does not contain the raw pattern either. The vendor-name pattern
# is case sensitive (lowercase) so a documentation sentence that spells the
# product name with a capital letter is not a hit, while real defaults such as
# command lines or configuration values are.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
XCCONFIG_REL="Configuration/AppIdentity.xcconfig"
XCCONFIG="$ROOT/$XCCONFIG_REL"
PBXPROJ_REL="PiWebDesktop.xcodeproj/project.pbxproj"
PBXPROJ="$ROOT/$PBXPROJ_REL"
SERVICE_CONFIG_REL="Sources/ServiceConfiguration.swift"
SERVICE_CONFIG="$ROOT/$SERVICE_CONFIG_REL"
SELF_REL="Scripts/check-identity.sh"
BUNDLE=${1:-"$ROOT/build/Pi-Web-Desktop.app"}
PLIST="$BUNDLE/Contents/Info.plist"

checks=0
failures=0

pass() {
  checks=$((checks + 1))
  printf 'ok   %s\n' "$1"
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  printf 'FAIL %s\n' "$1"
}

# Read one value from the single-source xcconfig and expand $(VAR) references.
# Same implementation as Scripts/build.sh: Xcode, the build script and this
# checker must interpret the file identically.
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

# Print every literal (non "$(...)") value assigned to a build setting in the
# pbxproj. References are allowed, copied literals are not.
pbxproj_literal_assignments() {
  awk -v key="$1" '
    {
      line = $0
      pattern = key "[ \t]*=[ \t]*[^;]*;"
      while (match(line, pattern)) {
        assignment = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        sub(/^[^=]*=[ \t]*/, "", assignment)
        sub(/;[ \t]*$/, "", assignment)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", assignment)
        gsub(/^"|"$/, "", assignment)
        if (assignment !~ /^\$\(/) print assignment
      }
    }
  ' "$PBXPROJ"
}

# Run "git grep" over the tracked tree. MATCHES holds stdout, GREP_STATUS holds
# 0 (matches), 1 (no matches) or the git error code.
git_scan() {
  MATCHES=''
  GREP_STATUS=0
  MATCHES=$(git -C "$ROOT" grep -nI "$@" 2>/dev/null) || GREP_STATUS=$?
}

scan_forbidden() {
  label=$1
  shift
  git_scan "$@"
  if [ "$GREP_STATUS" -eq 0 ]; then
    fail "$label"
    printf '%s\n' "$MATCHES" | sed 's/^/     /'
  elif [ "$GREP_STATUS" -eq 1 ]; then
    pass "$label"
  else
    fail "$label (git grep failed with status $GREP_STATUS)"
  fi
}

check_plist_value() {
  key=$1
  expected=$2
  actual=$(plutil -extract "$key" raw -o - "$PLIST" 2>/dev/null || true)
  if [ -z "$actual" ]; then
    fail "Info.plist $key is missing or empty (expected '$expected')"
  elif [ "$actual" = "$expected" ]; then
    pass "Info.plist $key matches the xcconfig ($actual)"
  else
    fail "Info.plist $key is '$actual' but the xcconfig expects '$expected'"
  fi
}

check_loopback_entries() {
  remaining=$1
  while [ -n "$remaining" ]; do
    case $remaining in
      *,*)
        token=${remaining%%,*}
        remaining=${remaining#*,}
        ;;
      *)
        token=$remaining
        remaining=''
        ;;
    esac
    case $token in
      127.0.0.1|localhost|::1)
        pass "service noProxy entry is loopback ($token)"
        ;;
      *)
        fail "service noProxy entry is not loopback: '$token'"
        ;;
    esac
  done
}

printf 'check-identity: single source is %s\n' "$XCCONFIG_REL"

# --- 1. single source -------------------------------------------------------
printf '\n== single source ==\n'
if [ ! -f "$XCCONFIG" ]; then
  fail "missing single source $XCCONFIG_REL"
  printf '\ncheck-identity: FAILED (1 of 1 checks failed)\n'
  exit 1
fi
pass "found $XCCONFIG_REL"

APP_DISPLAY_NAME=$(xcconfig_value APP_DISPLAY_NAME)
APP_BUNDLE_NAME=$(xcconfig_value APP_BUNDLE_NAME)
APP_EXECUTABLE_NAME=$(xcconfig_value APP_EXECUTABLE_NAME)
APP_ICON_NAME=$(xcconfig_value APP_ICON_NAME)
APP_MINIMUM_SYSTEM_VERSION=$(xcconfig_value APP_MINIMUM_SYSTEM_VERSION)
APP_BUNDLE_IDENTIFIER=$(xcconfig_value PRODUCT_BUNDLE_IDENTIFIER)
APP_VERSION=$(xcconfig_value MARKETING_VERSION)
APP_BUILD=$(xcconfig_value CURRENT_PROJECT_VERSION)

for entry in \
  "APP_DISPLAY_NAME=$APP_DISPLAY_NAME" \
  "APP_BUNDLE_NAME=$APP_BUNDLE_NAME" \
  "APP_EXECUTABLE_NAME=$APP_EXECUTABLE_NAME" \
  "APP_ICON_NAME=$APP_ICON_NAME" \
  "APP_MINIMUM_SYSTEM_VERSION=$APP_MINIMUM_SYSTEM_VERSION" \
  "PRODUCT_BUNDLE_IDENTIFIER=$APP_BUNDLE_IDENTIFIER" \
  "MARKETING_VERSION=$APP_VERSION" \
  "CURRENT_PROJECT_VERSION=$APP_BUILD"
do
  key=${entry%%=*}
  value=${entry#*=}
  if [ -n "$value" ]; then
    pass "xcconfig $key = $value"
  else
    fail "xcconfig $key is missing"
  fi
done

# --- 2. Xcode project -------------------------------------------------------
printf '\n== Xcode project ==\n'
if grep -q 'AppIdentity\.xcconfig' "$PBXPROJ" && grep -q 'baseConfigurationReference' "$PBXPROJ"; then
  pass "pbxproj references $XCCONFIG_REL through baseConfigurationReference"
else
  fail "pbxproj does not reference $XCCONFIG_REL through baseConfigurationReference"
fi

config_total=$(grep -o 'isa = XCBuildConfiguration;' "$PBXPROJ" | wc -l | tr -d ' ')
config_bound=$(grep -o 'baseConfigurationReference = ' "$PBXPROJ" | wc -l | tr -d ' ')
if [ "$config_total" -gt 0 ] && [ "$config_bound" -eq "$config_total" ]; then
  pass "pbxproj build configurations inherit $XCCONFIG_REL ($config_bound/$config_total)"
else
  fail "pbxproj build configurations inherit $XCCONFIG_REL ($config_bound/$config_total)"
fi

for key in \
  MARKETING_VERSION \
  CURRENT_PROJECT_VERSION \
  PRODUCT_BUNDLE_IDENTIFIER \
  PRODUCT_NAME \
  MACOSX_DEPLOYMENT_TARGET \
  INFOPLIST_KEY_CFBundleShortVersionString \
  INFOPLIST_KEY_CFBundleVersion \
  INFOPLIST_KEY_CFBundleDisplayName \
  INFOPLIST_KEY_CFBundleIconFile
do
  literals=$(pbxproj_literal_assignments "$key")
  if [ -z "$literals" ]; then
    pass "pbxproj has no literal value for $key"
  else
    fail "pbxproj has a literal value for $key: $(printf '%s' "$literals" | tr '\n' ' ')"
  fi
done

for literal in "$APP_BUNDLE_IDENTIFIER" "$APP_DISPLAY_NAME" "$APP_VERSION"; do
  [ -n "$literal" ] || continue
  if grep -qF "$literal" "$PBXPROJ"; then
    fail "pbxproj repeats the literal '$literal'"
  else
    pass "pbxproj does not repeat the literal '$literal'"
  fi
done

# --- 3. built bundle --------------------------------------------------------
printf '\n== built bundle ==\n'
if [ ! -f "$PLIST" ]; then
  fail "bundle Info.plist not found: $PLIST (run ./Scripts/build.sh first)"
else
  if plutil -lint "$PLIST" >/dev/null 2>&1; then
    pass "Info.plist is a valid property list"
  else
    fail "Info.plist is not a valid property list: $PLIST"
  fi

  check_plist_value CFBundleShortVersionString "$APP_VERSION"
  check_plist_value CFBundleVersion "$APP_BUILD"
  check_plist_value CFBundleIdentifier "$APP_BUNDLE_IDENTIFIER"
  check_plist_value CFBundleName "$APP_BUNDLE_NAME"
  check_plist_value CFBundleDisplayName "$APP_DISPLAY_NAME"
  check_plist_value CFBundleExecutable "$APP_EXECUTABLE_NAME"
  check_plist_value CFBundleIconFile "$APP_ICON_NAME"
  check_plist_value LSMinimumSystemVersion "$APP_MINIMUM_SYSTEM_VERSION"
fi

# --- 4. service defaults ----------------------------------------------------
printf '\n== service defaults ==\n'
if [ ! -f "$SERVICE_CONFIG" ]; then
  fail "missing $SERVICE_CONFIG_REL"
else
  default_hostname=$(sed -n 's/^[[:space:]]*static let defaultHostname[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "$SERVICE_CONFIG")
  default_proxy=$(sed -n 's/^[[:space:]]*static let defaultProxy[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "$SERVICE_CONFIG")
  default_noproxy=$(sed -n 's/^[[:space:]]*static let defaultNoProxy[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "$SERVICE_CONFIG")

  if [ "$default_hostname" = "127.0.0.1" ]; then
    pass "service default hostname is 127.0.0.1"
  else
    fail "service default hostname is not 127.0.0.1: '$default_hostname'"
  fi

  if [ -z "$default_proxy" ]; then
    pass "service default proxy is empty"
  else
    fail "service default proxy is not empty: '$default_proxy'"
  fi

  if [ -z "$default_noproxy" ]; then
    fail "service noProxy default is missing"
  else
    check_loopback_entries "$default_noproxy"
  fi
fi

# --- 5. repository text scan ------------------------------------------------
printf '\n== repository text scan ==\n'
if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "repository text scan needs a Git work tree at $ROOT"
else
  VENDOR_PATTERN='tail''scale'
  TAILNET_SUFFIX_PATTERN='\.ts\.net'
  CGNAT_PATTERN='100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'
  HOME_PATH_PATTERN='/Users/[A-Za-z0-9._-]+'
  PROXY_ENDPOINT_PATTERN='(127\.0\.0\.1|localhost|\[::1\]):(7890|7891|1080|10809|3128|8888)'

  scan_forbidden "no Tailscale default hostname" -E -e "$VENDOR_PATTERN" -- ":!$SELF_REL" ':!*.icns'
  scan_forbidden "no tailnet DNS suffix default" -E -i -e "$TAILNET_SUFFIX_PATTERN" -- ":!$SELF_REL" ':!*.icns'
  scan_forbidden "no CGNAT private address default" -E -e "$CGNAT_PATTERN" -- ":!$SELF_REL" ':!*.icns'
  scan_forbidden "no absolute home path default" -E -e "$HOME_PATH_PATTERN" -- ":!$SELF_REL" ':!*.icns'
  scan_forbidden "no fixed local proxy endpoint default" -E -i -e "$PROXY_ENDPOINT_PATTERN" -- ":!$SELF_REL" ':!*.icns'

  if [ -n "$APP_VERSION" ]; then
    scan_forbidden "no hardcoded MARKETING_VERSION outside $XCCONFIG_REL" -F -e "$APP_VERSION" -- Sources Scripts PiWebDesktop.xcodeproj PiWebDesktopTests
  fi
fi

# --- summary ----------------------------------------------------------------
if [ "$failures" -eq 0 ]; then
  printf '\ncheck-identity: PASSED (%s checks)\n' "$checks"
  exit 0
fi

printf '\ncheck-identity: FAILED (%s of %s checks failed)\n' "$failures" "$checks"
exit 1
