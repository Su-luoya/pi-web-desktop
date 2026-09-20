#!/bin/sh
set -eu

# Assert that a release tag agrees with the single version source,
# Configuration/AppIdentity.xcconfig:
#
#   1. the tag is exactly "v<MARKETING_VERSION>";
#   2. CURRENT_PROJECT_VERSION is the build number MARKETING_VERSION derives:
#        * pre-release with a counter, e.g. 1.2.3-alpha.4 -> 4
#          ("<stage>.<N>" or a bare "<N>" after the hyphen);
#        * release without a pre-release counter, e.g. 1.2.3 -> 1002003
#          (major * 1000000 + minor * 1000 + patch, each part at most 999);
#        * a pre-release without a counter, e.g. 1.2.3-beta, is refused because
#          the tag would not pin a build number.
#
# The build rule is applied every time the version source is readable, with or
# without a tag argument: a build number that drifted away from
# MARKETING_VERSION fails even in a local rehearsal that has no tag. That was
# the gap this rule closes (code review W4 / M5): a stable tag used to skip the
# CURRENT_PROJECT_VERSION comparison entirely.
#
# The rule is documented in docs/releasing.md ("版本来源与 Git tag").
#
# Usage:
#   ./Scripts/check-release-version.sh [--print-tag] [tag]
#   ./Scripts/check-release-version.sh --self-test
#
# The tag comes from the first positional argument, or from GITHUB_REF_NAME when
# no argument is given, which is how .github/workflows/release.yml calls this
# script. With neither, the script validates the version source and prints the
# tag it expects, then exits 0: a local checkout usually has no release tag and
# the packaging rehearsal has to stay runnable without one.
#
# --print-tag prints the tag derived from MARKETING_VERSION and exits. The
# release workflow uses it for a workflow_dispatch rehearsal whose ref is not a
# tag, so the rehearsal still exercises the same comparison code path.
#
# --self-test runs fixture cases in a temporary directory outside the work tree
# (version/build/tag combinations that must pass and combinations that must
# fail) and exits without reading the work tree's version source.
#
# Version values are never written into this script; they are read from
# Configuration/AppIdentity.xcconfig with the same parser as Scripts/build.sh
# and Scripts/check-identity.sh, so the three always interpret the file the same
# way.
#
# Exit status: 0 consistent or skipped, 1 inconsistent, 2 usage error.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
XCCONFIG_REL="Configuration/AppIdentity.xcconfig"
XCCONFIG="$ROOT/$XCCONFIG_REL"

usage() {
  printf 'usage: ./Scripts/check-release-version.sh [--print-tag] [tag]\n'
  printf '       ./Scripts/check-release-version.sh --self-test\n'
}

usage_error() {
  printf 'error: %s\n' "$1" >&2
  usage >&2
  exit 2
}

fail() {
  printf 'check-release-version: FAILED\n' >&2
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# Read one value from the single-source xcconfig, expanding $(VAR) references.
# Same parser as Scripts/build.sh and Scripts/check-identity.sh.
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

# normalize_int VALUE: print VALUE without leading zeros so two numeric build
# numbers can be compared as strings without depending on the shell's integer
# range. Prints 0 when VALUE has no digits.
normalize_int() {
  value=$1
  while [ "${#value}" -gt 1 ]; do
    case $value in
      0*) value=${value#0} ;;
      *) break ;;
    esac
  done
  case $value in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$value" ;;
  esac
}

# expected_build_for_version VERSION: print the build number VERSION derives and
# return 0, or print nothing and return 1 when VERSION cannot carry one. The
# rule is the one documented in docs/releasing.md; keep both in sync.
expected_build_for_version() {
  version=$1

  case $version in
    *-*)
      has_prerelease=1
      prerelease=${version#*-}
      ;;
    *)
      has_prerelease=0
      prerelease=''
      ;;
  esac

  # The release part must be exactly three numeric components, each at most
  # three digits: the release key is major*1000000 + minor*1000 + patch, so a
  # longer component would overlap the next one.
  core=${version%%-*}
  case $core in
    *.*.*) ;;
    *) return 1 ;;
  esac
  major=${core%%.*}
  rest=${core#*.}
  minor=${rest%%.*}
  patch=${rest#*.}
  case $patch in
    *.*) return 1 ;;
  esac
  for part in "$major" "$minor" "$patch"; do
    case $part in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#part}" -le 3 ] || return 1
  done
  # Strip leading zeros before the arithmetic below: a component like "09" is
  # still a decimal part here, but shell arithmetic would read it as octal.
  major=$(normalize_int "$major")
  minor=$(normalize_int "$minor")
  patch=$(normalize_int "$patch")

  if [ "$has_prerelease" -eq 1 ]; then
    [ -n "$prerelease" ] || return 1
    case $prerelease in
      *[!0-9]*)
        # A pre-release with a non-numeric stage must end in a numeric counter.
        case $prerelease in
          *.*) ;;
          *) return 1 ;;
        esac
        counter=${prerelease##*.}
        case $counter in
          ''|*[!0-9]*) return 1 ;;
        esac
        ;;
      *)
        # A bare numeric pre-release is the counter itself.
        counter=$prerelease
        ;;
    esac
    normalize_int "$counter"
    return 0
  fi

  printf '%s\n' "$((major * 1000000 + minor * 1000 + patch))"
  return 0
}

# --- self-test ---------------------------------------------------------------

# Scratch directory for --self-test. It is created outside $ROOT and removed
# again, also when a case fails.
TMP_DIR=
cleanup_temp_dir() {
  if [ -n "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
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
  mktemp -d "$base/pi-web-desktop-check-release-version.XXXXXX"
}

# self_test_case LABEL VERSION BUILD TAG EXPECTED [EXPECTED_TEXT]
#   EXPECTED is accept (exit 0) or reject (exit 1).
#   BUILD is written as CURRENT_PROJECT_VERSION unless it is the literal
#   "missing"; TAG is passed to the script unless it is the literal "no-tag",
#   which also clears GITHUB_REF_NAME.
#   EXPECTED_TEXT, when given, must appear in the script output.
self_test_case() {
  label=$1
  version=$2
  build=$3
  tag=$4
  expected=$5
  expect_text=${6:-}

  config="$TMP_DIR/repo/Configuration/AppIdentity.xcconfig"
  {
    printf 'MARKETING_VERSION = %s\n' "$version"
    if [ "$build" != "missing" ]; then
      printf 'CURRENT_PROJECT_VERSION = %s\n' "$build"
    fi
  } > "$config"

  set --
  if [ "$tag" != "no-tag" ]; then
    set -- "$tag"
  fi

  status=0
  output=$(env -u GITHUB_REF_NAME "$TMP_DIR/repo/Scripts/check-release-version.sh" "$@" 2>&1) || status=$?

  actual=accept
  [ "$status" -eq 0 ] || actual=reject

  ok=1
  if [ "$actual" != "$expected" ]; then
    printf 'self-test: FAIL: %s -> %s (exit %s), expected %s\n' "$label" "$actual" "$status" "$expected" >&2
    ok=0
  fi
  if [ -n "$expect_text" ]; then
    case $output in
      *"$expect_text"*) ;;
      *)
        printf 'self-test: FAIL: %s output does not contain "%s"\n' "$label" "$expect_text" >&2
        ok=0
        ;;
    esac
  fi

  if [ "$ok" -eq 1 ]; then
    printf 'self-test: ok: %s -> %s\n' "$label" "$actual"
  else
    printf '%s\n' "$output" | tail -n 4 | sed 's/^/      /' >&2
    failures=$((failures + 1))
  fi
}

self_test() {
  failures=0

  # The self-test must not touch the work tree: the script is copied into a
  # temporary directory outside $ROOT, its copy resolves ROOT there, and the
  # fixtures live in the copy's Configuration/ directory.
  TMP_DIR=$(self_test_temp_dir) || return 1
  case $TMP_DIR in
    "$ROOT"|"$ROOT"/*)
      printf 'self-test: FAIL: scratch directory %s is inside the repository\n' "$TMP_DIR" >&2
      return 1
      ;;
  esac
  mkdir -p "$TMP_DIR/repo/Scripts" "$TMP_DIR/repo/Configuration"
  if ! cp "$ROOT/Scripts/check-release-version.sh" "$TMP_DIR/repo/Scripts/check-release-version.sh"; then
    printf 'self-test: FAIL: cannot copy Scripts/check-release-version.sh into %s\n' "$TMP_DIR" >&2
    return 1
  fi
  chmod +x "$TMP_DIR/repo/Scripts/check-release-version.sh"

  # Fixture versions deliberately use a line that is not this repository's
  # MARKETING_VERSION, so the self-test never has to embed a version literal.
  printf 'self-test: release tag build rule\n'
  self_test_case 'stable tag with the derived build number' '9.9.9' '9009009' 'v9.9.9' accept 'matches the build rule'
  self_test_case 'stable tag with a stale build number (M5)' '9.9.9' '4' 'v9.9.9' reject 'requires CURRENT_PROJECT_VERSION=9009009'
  self_test_case 'stable tag with an oversized build number (M5)' '9.9.9' '999' 'v9.9.9' reject 'requires CURRENT_PROJECT_VERSION=9009009'
  self_test_case 'stable tag with a non-numeric build number' '9.9.9' 'next' 'v9.9.9' reject 'non-negative integer'
  self_test_case 'stable tag with the build number missing' '9.9.9' 'missing' 'v9.9.9' reject 'must define both MARKETING_VERSION and CURRENT_PROJECT_VERSION'
  self_test_case 'stable tag with a two-component version' '9.9' '9' 'v9.9' reject 'cannot derive a build number'

  printf 'self-test: pre-release counters\n'
  self_test_case 'pre-release counter matches' '9.9.9-alpha.7' '7' 'v9.9.9-alpha.7' accept 'matches the build rule'
  self_test_case 'pre-release counter drifts' '9.9.9-alpha.7' '8' 'v9.9.9-alpha.7' reject 'requires CURRENT_PROJECT_VERSION=7'
  self_test_case 'bare numeric pre-release matches' '9.9.9-7' '7' 'v9.9.9-7' accept 'matches the build rule'
  self_test_case 'pre-release without a counter' '9.9.9-beta' '7' 'v9.9.9-beta' reject 'cannot derive a build number'
  self_test_case 'pre-release with a non-numeric counter' '9.9.9-rc.x' '7' 'v9.9.9-rc.x' reject 'cannot derive a build number'

  printf 'self-test: build rule without a tag argument\n'
  self_test_case 'no tag, counter matches' '9.9.9-alpha.7' '7' 'no-tag' accept 'tag comparison is skipped'
  self_test_case 'no tag, counter drifts' '9.9.9-alpha.7' '8' 'no-tag' reject 'requires CURRENT_PROJECT_VERSION=7'
  self_test_case 'no tag, stable build drifts' '9.9.9' '4' 'no-tag' reject 'requires CURRENT_PROJECT_VERSION=9009009'

  printf 'self-test: tag checks\n'
  self_test_case 'tag does not match MARKETING_VERSION' '9.9.9-alpha.7' '7' 'v9.9.10-alpha.7' reject 'does not match'
  self_test_case 'branch-like ref instead of a tag' '9.9.9-alpha.7' '7' 'main' reject 'is not a release tag'

  if [ "$failures" -ne 0 ]; then
    printf 'self-test: FAILED (%s failure(s))\n' "$failures" >&2
    return 1
  fi
  printf 'self-test: PASS (release build rule, pre-release counters, no-tag rehearsal, tag checks; scratch directory cleaned up)\n'
  return 0
}

PRINT_TAG=0
SELF_TEST=0
TAG=''
for argument in "$@"; do
  case $argument in
    --print-tag)
      PRINT_TAG=1
      ;;
    --self-test)
      SELF_TEST=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage_error "unknown option $argument"
      ;;
    *)
      if [ -n "$TAG" ]; then
        usage_error 'expected at most one tag argument'
      fi
      TAG=$argument
      ;;
  esac
done

if [ "$PRINT_TAG" -eq 1 ] && [ -n "$TAG" ]; then
  usage_error '--print-tag cannot be combined with a tag argument'
fi
if [ "$SELF_TEST" -eq 1 ]; then
  if [ "$PRINT_TAG" -eq 1 ] || [ -n "$TAG" ]; then
    usage_error '--self-test does not take --print-tag or a tag argument'
  fi
  if self_test; then
    exit 0
  fi
  exit 1
fi

if [ ! -f "$XCCONFIG" ]; then
  fail "missing version source $XCCONFIG_REL (run this script from the repository it belongs to)"
fi

VERSION=$(xcconfig_value MARKETING_VERSION)
BUILD=$(xcconfig_value CURRENT_PROJECT_VERSION)

if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
  fail "$XCCONFIG_REL must define both MARKETING_VERSION and CURRENT_PROJECT_VERSION (MARKETING_VERSION='${VERSION}', CURRENT_PROJECT_VERSION='${BUILD}')"
fi

EXPECTED_TAG="v$VERSION"

if [ "$PRINT_TAG" -eq 1 ]; then
  printf '%s\n' "$EXPECTED_TAG"
  exit 0
fi

printf 'check-release-version: version source %s\n' "$XCCONFIG_REL"
printf 'check-release-version: MARKETING_VERSION = %s, CURRENT_PROJECT_VERSION = %s\n' "$VERSION" "$BUILD"
printf 'check-release-version: expected tag = %s\n' "$EXPECTED_TAG"

if [ -z "$TAG" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
  TAG=$GITHUB_REF_NAME
  printf 'check-release-version: using GITHUB_REF_NAME = %s\n' "$TAG"
fi

if [ -n "$TAG" ]; then
  case $TAG in
    v*) ;;
    *)
      fail "'$TAG' is not a release tag: expected '$EXPECTED_TAG'. Ref names such as branch names can never match a version tag; pass the release tag explicitly or check the protected v* tag that triggered the run."
      ;;
  esac

  if [ "$TAG" != "$EXPECTED_TAG" ]; then
    fail "tag '$TAG' does not match $XCCONFIG_REL: MARKETING_VERSION=$VERSION expects tag '$EXPECTED_TAG'. Fix MARKETING_VERSION, or move the tag to the commit that has the right version; see docs/releasing.md."
  fi
  printf 'ok   tag %s matches MARKETING_VERSION\n' "$TAG"
else
  printf 'check-release-version: no tag argument and no GITHUB_REF_NAME, so the tag comparison is skipped\n'
  printf 'check-release-version: compare a tag locally with: ./Scripts/check-release-version.sh %s\n' "$EXPECTED_TAG"
fi

# The build rule always applies, tag or no tag: CURRENT_PROJECT_VERSION is the
# value that reaches CFBundleVersion, so a stable release must not skip it.
case $BUILD in
  ''|*[!0-9]*)
    fail "CURRENT_PROJECT_VERSION='$BUILD' in $XCCONFIG_REL is not a non-negative integer. The build number must be a plain decimal counter; see docs/releasing.md."
    ;;
esac
NORMALIZED_BUILD=$(normalize_int "$BUILD")
if [ "$BUILD" != "$NORMALIZED_BUILD" ]; then
  fail "CURRENT_PROJECT_VERSION='$BUILD' has leading zeros; write it as '$NORMALIZED_BUILD' in $XCCONFIG_REL"
fi

EXPECTED_BUILD=$(expected_build_for_version "$VERSION") || fail "MARKETING_VERSION=$VERSION cannot derive a build number. Accepted shapes are 'X.Y.Z' (each part at most three digits, e.g. 1.2.3) and pre-release tags with a numeric counter (e.g. 1.2.3-alpha.4 or 1.2.3-4); MARKETING_VERSION and the Git tag share the same value; see docs/releasing.md."

if [ "$BUILD" != "$EXPECTED_BUILD" ]; then
  fail "MARKETING_VERSION=$VERSION requires CURRENT_PROJECT_VERSION=$EXPECTED_BUILD under the build rule in docs/releasing.md, but $XCCONFIG_REL sets CURRENT_PROJECT_VERSION=$BUILD. Set CURRENT_PROJECT_VERSION=$EXPECTED_BUILD (and rebuild so CFBundleVersion matches), or fix MARKETING_VERSION."
fi
printf 'ok   CURRENT_PROJECT_VERSION=%s matches the build rule for MARKETING_VERSION=%s\n' "$BUILD" "$VERSION"

if [ -n "$TAG" ]; then
  printf 'check-release-version: PASSED (tag %s, MARKETING_VERSION %s, CURRENT_PROJECT_VERSION %s)\n' "$TAG" "$VERSION" "$BUILD"
else
  printf 'check-release-version: PASSED (MARKETING_VERSION %s, CURRENT_PROJECT_VERSION %s; tag comparison skipped)\n' "$VERSION" "$BUILD"
fi
exit 0
