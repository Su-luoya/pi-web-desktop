#!/bin/sh
set -eu

# Assert that a release tag agrees with the single version source,
# Configuration/AppIdentity.xcconfig:
#
#   1. the tag is exactly "v<MARKETING_VERSION>";
#   2. when the tag carries a numeric pre-release counter (the trailing number
#      of a tag such as v<MARKETING_VERSION>), that counter equals
#      CURRENT_PROJECT_VERSION.
#
# Usage:
#   ./Scripts/check-release-version.sh [--print-tag] [tag]
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

PRINT_TAG=0
TAG=''
for argument in "$@"; do
  case $argument in
    --print-tag)
      PRINT_TAG=1
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

if [ -z "$TAG" ]; then
  printf 'check-release-version: no tag argument and no GITHUB_REF_NAME, so the tag comparison is skipped\n'
  printf 'check-release-version: compare a tag locally with: ./Scripts/check-release-version.sh %s\n' "$EXPECTED_TAG"
  printf 'check-release-version: PASSED (version source readable; tag comparison skipped)\n'
  exit 0
fi

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

# v1.2.3-alpha.4 -> prerelease "alpha.4" -> trailing number 4, which must be
# CURRENT_PROJECT_VERSION. A tag without a numeric pre-release counter (v1.2.3,
# v1.2.3-beta) cannot be compared this way; the built bundles are compared with
# CURRENT_PROJECT_VERSION by Scripts/check-identity.sh instead.
PRERELEASE=''
case $VERSION in
  *-*) PRERELEASE=${VERSION#*-} ;;
esac

COUNTER=''
if [ -n "$PRERELEASE" ]; then
  case $PRERELEASE in
    *.*)
      LAST=${PRERELEASE##*.}
      case $LAST in
        ''|*[!0-9]*) COUNTER='' ;;
        *) COUNTER=$LAST ;;
      esac
      ;;
  esac
fi

if [ -z "$COUNTER" ]; then
  printf 'info tag %s has no numeric pre-release counter; CURRENT_PROJECT_VERSION=%s is asserted against the built bundles by ./Scripts/check-identity.sh instead\n' "$TAG" "$BUILD"
  printf 'check-release-version: PASSED (tag %s matches MARKETING_VERSION %s; no derivable build counter)\n' "$TAG" "$VERSION"
  exit 0
fi

if [ "$COUNTER" != "$BUILD" ]; then
  fail "tag '$TAG' pre-release counter '$COUNTER' does not match CURRENT_PROJECT_VERSION=$BUILD in $XCCONFIG_REL. Set CURRENT_PROJECT_VERSION=$COUNTER for this release, or move the tag; see docs/releasing.md."
fi
printf 'ok   tag pre-release counter %s matches CURRENT_PROJECT_VERSION\n' "$COUNTER"

printf 'check-release-version: PASSED (tag %s, MARKETING_VERSION %s, CURRENT_PROJECT_VERSION %s)\n' "$TAG" "$VERSION" "$BUILD"
exit 0
