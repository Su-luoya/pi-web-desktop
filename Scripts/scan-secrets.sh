#!/bin/sh
# scan-secrets.sh - repository secret scan (GitHub #11).
#
# Scope: high-signal credential shapes a reviewer can act on immediately:
#   * AWS access key IDs (`AKIA` + 16 uppercase/digit characters)
#   * GitHub tokens (`ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`/`github_pat_` + suffix)
#   * PEM private key headers
#   * JWTs (`eyJ...` three base64url segments)
#   * `password=` / `passwd=` / `secret=` / `api_key=` / `token=` assignments
#     with a literal value of at least 12 characters
#
# This is not a general secret scanner: the rules are fixed regexes, so a
# credential that does not match one of these shapes is not reported. It is a
# complement to, not a replacement for, review and the personal-data scan.
#
# Usage:
#   Scripts/scan-secrets.sh                 # scan every git-tracked file
#   Scripts/scan-secrets.sh FILE [FILE...]  # scan explicit files
#   Scripts/scan-secrets.sh --self-test     # prove every rule fires, in a temp dir
#
# Exit codes: 0 = no matches, 1 = at least one match, 2 = usage/environment error.
#
# The rules and the self-test samples are assembled from adjacent shell string
# literals, so this file never contains a contiguous example of its own
# patterns; a secret committed into this script is still reported because the
# scan reads the file's bytes, not this construction.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# --- rules -----------------------------------------------------------------

# AWS access key ID: `AKIA` followed by 16 uppercase letters or digits.
RULE_AWS='AKIA[0-9A-Z]{16}'

# GitHub token prefixes plus a long suffix. `github_pat_` uses underscores and
# is listed separately because its body class differs.
RULE_GITHUB='gh[pousr]_[A-Za-z0-9]{20,}'
RULE_GITHUB_PAT='github_pat_[A-Za-z0-9_]{20,}'

# PEM private key header (RSA/EC/OPENSSH/DSA and the PGP block form).
RULE_PRIVATE_KEY='-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----'

# JWT: header.payload.signature, each segment at least 8 base64url characters.
RULE_JWT='eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'

# Assignment-style secrets. The key must be attached to `=` (config/code leaks
# look like `api_key=...`, not like a prose sentence); the value must be a
# 12+ character literal without whitespace so ordinary prose and identifiers
# such as `secret = "..."` in source (which has spaces around `=`) stay clean.
RULE_ASSIGNMENT='(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|token)=[[:space:]]*"?[A-Za-z0-9_./+@%-]{12,}'

RULE_ALL="($RULE_AWS)|($RULE_GITHUB)|($RULE_GITHUB_PAT)|($RULE_PRIVATE_KEY)|($RULE_JWT)|($RULE_ASSIGNMENT)"

# --- scanning --------------------------------------------------------------

# scan_file FILE: prints matches; returns 0 when the file matched, 1 when clean.
scan_file() {
    grep -nE -e "$RULE_ALL" -- "$1"
}

# scan_repository: `git grep` over every tracked file; returns 0 on match,
# 1 on clean and 2 when the scan itself could not run.
scan_repository() {
    if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'scan-secrets: error: %s is not a git work tree\n' "$ROOT" >&2
        return 2
    fi
    status=0
    git -C "$ROOT" grep -nIE -e "$RULE_ALL" -- . || status=$?
    case $status in
        0) return 0 ;;
        1) return 1 ;;
        *)
            printf 'scan-secrets: error: git grep failed with status %s\n' "$status" >&2
            return 2
            ;;
    esac
}

usage() {
    cat <<'USAGE'
Usage: Scripts/scan-secrets.sh [FILE...]
       Scripts/scan-secrets.sh --self-test

Without arguments every git-tracked file is scanned. Explicit files are useful
for checking a candidate file before it is committed. --self-test writes sample
files into a temporary directory, asserts that each rule fires there, asserts
that harmless sample text is not reported, and removes the directory again.
USAGE
}

# --- self-test -------------------------------------------------------------

self_test() {
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/pi-web-desktop-scan-secrets.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    failures=0

    # Samples are concatenated at runtime so the committed script never holds a
    # matching literal itself.
    sample_aws='AKIA'"ABCDEFGHIJKLMNOP"
    sample_github='gho_'"0123456789abcdefghijABCDEFGHIJ"
    sample_github_pat='github_pat_'"11ABCDEFG0abcdefghijklmnopqrstuvwxyz234567"
    sample_private_key="-----BEGIN RSA"" PRIVATE KEY-----"
    sample_jwt=$(printf '%s.%s.%s' 'eyJhbGciOiJIUzI1NiJ9' 'eyJzdWIiOiIxMjM0NTY3ODkwIn0' 'c2lnbmF0dXJlLXNlY3Rpb24')
    sample_assignment='api_key='"AbCdEf0123456789xyz"

    printf 'aws: %s\n' "$sample_aws" > "$tmp/aws.txt"
    printf 'github: %s\n' "$sample_github" > "$tmp/github.txt"
    printf 'github_pat: %s\n' "$sample_github_pat" > "$tmp/github_pat.txt"
    printf '%s\n' "$sample_private_key" > "$tmp/private_key.txt"
    printf 'Authorization: Bearer %s\n' "$sample_jwt" > "$tmp/jwt.txt"
    printf '%s\n' "$sample_assignment" > "$tmp/assignment.txt"

    expect_hit() {
        label=$1
        file=$2
        status=0
        scan_file "$file" >/dev/null 2>&1 || status=$?
        case $status in
            0)
                printf 'self-test: ok: %s is detected\n' "$label"
                ;;
            1)
                printf 'self-test: FAIL: %s was not detected\n' "$label" >&2
                failures=$((failures + 1))
                ;;
            *)
                printf 'self-test: FAIL: scanning %s failed with status %s\n' "$label" "$status" >&2
                failures=$((failures + 1))
                ;;
        esac
    }

    expect_clean() {
        label=$1
        file=$2
        status=0
        scan_file "$file" >/dev/null 2>&1 || status=$?
        case $status in
            1)
                printf 'self-test: ok: %s is not reported\n' "$label"
                ;;
            0)
                printf 'self-test: FAIL: %s was reported as a secret:\n' "$label" >&2
                scan_file "$file" >&2 || true
                failures=$((failures + 1))
                ;;
            *)
                printf 'self-test: FAIL: scanning %s failed with status %s\n' "$label" "$status" >&2
                failures=$((failures + 1))
                ;;
        esac
    }

    expect_hit "AWS access key ID" "$tmp/aws.txt"
    expect_hit "GitHub token" "$tmp/github.txt"
    expect_hit "GitHub fine-grained PAT" "$tmp/github_pat.txt"
    expect_hit "PEM private key header" "$tmp/private_key.txt"
    expect_hit "JWT" "$tmp/jwt.txt"
    expect_hit "assignment-style secret" "$tmp/assignment.txt"

    # Harmless look-alikes must stay clean: the prefix without a long body, an
    # empty assignment, a prose mention and a key with spaces around `=`.
    {
        printf 'prefixonly: AKIA\n'
        printf 'empty: password=\n'
        printf 'prose: rotate the api_key= value in the config\n'
        printf 'spaced: secret = "unit-test-value-0123456789"\n'
        printf 'documentation: BEGIN PRIVATE KEY is not a header\n'
    } > "$tmp/clean.txt"
    expect_clean "placeholder-ish text" "$tmp/clean.txt"

    if [ "$failures" -ne 0 ]; then
        printf 'self-test: FAILED (%s failure(s))\n' "$failures" >&2
        return 1
    fi
    printf 'self-test: PASS (all rules fired, samples cleaned up)\n'
    return 0
}

# --- entry point -----------------------------------------------------------

if [ "$#" -eq 0 ]; then
    if scan_repository; then
        printf 'scan-secrets: FAIL: matches listed above\n' >&2
        exit 1
    else
        status=$?
    fi
    if [ "$status" -ne 1 ]; then
        exit "$status"
    fi
    printf 'scan-secrets: PASS (no matches in tracked files)\n'
    exit 0
fi

case $1 in
    --self-test)
        shift
        if [ "$#" -ne 0 ]; then
            printf 'scan-secrets: error: --self-test takes no further arguments\n' >&2
            exit 2
        fi
        self_test
        exit $?
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    -*)
        printf 'scan-secrets: error: unknown option %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
esac

found=0
for path in "$@"; do
    if [ ! -f "$path" ]; then
        printf 'scan-secrets: error: %s is not a file\n' "$path" >&2
        exit 2
    fi
    if scan_file "$path"; then
        found=1
    fi
done

if [ "$found" -ne 0 ]; then
    printf 'scan-secrets: FAIL: matches listed above\n' >&2
    exit 1
fi
printf 'scan-secrets: PASS (no matches)\n'
exit 0
