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
# Inline suppression: a matched line is skipped only when that same line also
# contains `scan-secrets: allow`. The marker exists for lines whose text is
# deliberately credential-shaped sample data (redaction test fixtures); it must
# not be used to mute a real finding, and it never exempts a whole file or
# directory. Every run ends with `scan-secrets: suppressed N lines`, so a
# reviewer can see how many hits were muted, and --self-test asserts that the
# marker suppresses exactly its own line and that the counter is right.
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

# --- suppression marker ------------------------------------------------------

# A matched line is skipped only when the matched line itself contains this
# marker. The check is per line on purpose: there is no file, directory or
# pathspec exemption anywhere in this script.
SUPPRESS_MARKER='scan-secrets: allow'

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

# --- scratch space -----------------------------------------------------------

# Scratch directories are created outside $ROOT so neither the repository scan
# nor --self-test ever writes into the work tree. `cleanup` removes whatever
# exists, also when the scan exits through an error path.
TMP_SAMPLES=
TMP_SCAN=
SUPPRESSED_COUNT=

cleanup() {
    if [ -n "$TMP_SAMPLES" ]; then
        rm -rf "$TMP_SAMPLES"
    fi
    if [ -n "$TMP_SCAN" ]; then
        rm -rf "$TMP_SCAN"
    fi
}
trap cleanup EXIT

# make_temp_dir: print the path of a fresh scratch directory outside $ROOT.
make_temp_dir() {
    base=${TMPDIR:-/tmp}
    if resolved=$(CDPATH= cd -- "$base" 2>/dev/null && pwd); then
        base=$resolved
    else
        base=/tmp
    fi
    case $base in
        "$ROOT"|"$ROOT"/*) base=/tmp ;;
    esac
    mktemp -d "$base/pi-web-desktop-scan-secrets.XXXXXX"
}

# ensure_scan_tmp: create the scratch directory used for raw match records on
# first use and point SUPPRESSED_COUNT at the counter file inside it.
ensure_scan_tmp() {
    if [ -z "$TMP_SCAN" ]; then
        TMP_SCAN=$(make_temp_dir)
        SUPPRESSED_COUNT="$TMP_SCAN/suppressed.count"
    fi
}

# suppressed_count: print how many matched lines were skipped by the marker.
suppressed_count() {
    if [ -n "$SUPPRESSED_COUNT" ] && [ -f "$SUPPRESSED_COUNT" ]; then
        cat "$SUPPRESSED_COUNT"
    else
        printf '0\n'
    fi
}

# report_suppressed: the end-of-run summary that keeps suppression auditable.
report_suppressed() {
    printf 'scan-secrets: suppressed %s lines\n' "$(suppressed_count)"
}

# --- scanning --------------------------------------------------------------

# filter_hits RECORD_FILE: print the records that are not suppressed and count
# the skipped ones. A record has the `<path>:<line>:<text>` shape produced by
# `git grep -n` and `grep -Hn`, so only the matched line itself decides whether
# the marker applies; a marker elsewhere in the same file does not. A record
# whose prefix cannot be parsed (for example a path containing `:`) is reported
# rather than suppressed, because the scanner must fail loudly instead of
# hiding a finding. Returns 0 when at least one record was printed, 1 otherwise.
filter_hits() {
    awk -v marker="$SUPPRESS_MARKER" -v counter="$SUPPRESSED_COUNT" '
        {
            content = ""
            if (match($0, /^[^:]*:[0-9]+:/)) {
                content = substr($0, RSTART + RLENGTH)
            }
            if (content != "" && index(content, marker) > 0) {
                suppressed++
                next
            }
            print
            printed++
        }
        END {
            if (suppressed > 0) {
                base = 0
                if ((getline previous < counter) > 0) base = previous + 0
                close(counter)
                printf "%d\n", base + suppressed > counter
            }
            exit (printed > 0 ? 0 : 1)
        }
    ' "$1"
}

# scan_file FILE: print non-suppressed matches; 0 = at least one match printed,
# 1 = clean or fully suppressed, 2 = the file could not be scanned.
scan_file() {
    ensure_scan_tmp
    records="$TMP_SCAN/file-matches"
    status=0
    grep -HnE -e "$RULE_ALL" -- "$1" > "$records" || status=$?
    case $status in
        0) filter_hits "$records" ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# scan_repository: `git grep` over every tracked file; 0 = at least one match
# printed, 1 = clean or fully suppressed, 2 = the scan itself could not run.
scan_repository() {
    if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'scan-secrets: error: %s is not a git work tree\n' "$ROOT" >&2
        return 2
    fi
    ensure_scan_tmp
    records="$TMP_SCAN/repository-matches"
    status=0
    git -C "$ROOT" grep -nIE -e "$RULE_ALL" -- . > "$records" || status=$?
    case $status in
        0) filter_hits "$records" ;;
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
for checking a candidate file before it is committed. A matched line is skipped
only when that same line contains `scan-secrets: allow`; the run always ends
with `scan-secrets: suppressed N lines`. --self-test writes sample files into a
temporary directory outside the repository, asserts that each rule fires there,
asserts that harmless sample text is not reported, asserts that the inline
marker suppresses exactly its own line and is counted correctly, and removes
the directory again.
USAGE
}

# --- self-test -------------------------------------------------------------

self_test() {
    TMP_SAMPLES=$(make_temp_dir)
    tmp=$TMP_SAMPLES

    # The self-test must not touch the work tree: samples and scratch records
    # live under a directory created outside $ROOT and are removed again.
    case $tmp in
        "$ROOT"|"$ROOT"/*)
            printf 'self-test: FAIL: sample directory %s is inside the repository\n' "$tmp" >&2
            return 1
            ;;
    esac

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

    # Inline suppression: the marker must skip exactly the matched line that
    # carries it. The same text without the marker is still reported; a marker
    # on another line of the same file does not suppress the match; a marker
    # without any credential shape matches nothing and is not counted.
    sample_suppressable='token='"suppressed-sample-value"
    printf '%s  # %s\n' "$sample_suppressable" "$SUPPRESS_MARKER" > "$tmp/suppressed.txt"
    printf '%s\n' "$sample_suppressable" > "$tmp/unsuppressed.txt"
    {
        printf '# %s\n' "$SUPPRESS_MARKER"
        printf '%s\n' "$sample_suppressable"
    } > "$tmp/marker_elsewhere.txt"
    printf '# %s\n' "$SUPPRESS_MARKER" > "$tmp/marker_only.txt"

    before_marked=$(suppressed_count)
    expect_clean "a matched line carrying the suppression marker" "$tmp/suppressed.txt"
    after_marked=$(suppressed_count)
    if [ "$after_marked" -eq $((before_marked + 1)) ]; then
        printf 'self-test: ok: suppression counter grew by exactly 1 (%s -> %s)\n' \
            "$before_marked" "$after_marked"
    else
        printf 'self-test: FAIL: suppression counter went %s -> %s, expected %s\n' \
            "$before_marked" "$after_marked" "$((before_marked + 1))" >&2
        failures=$((failures + 1))
    fi

    expect_hit "the same matched line without the suppression marker" "$tmp/unsuppressed.txt"
    expect_hit "a matched line in a file whose marker sits on another line" "$tmp/marker_elsewhere.txt"
    expect_clean "a suppression marker with no credential shape" "$tmp/marker_only.txt"

    after_unmarked=$(suppressed_count)
    if [ "$after_unmarked" -eq "$after_marked" ]; then
        printf 'self-test: ok: counter stayed at %s for lines that must not be suppressed\n' \
            "$after_unmarked"
    else
        printf 'self-test: FAIL: counter moved from %s to %s for lines that must not be suppressed\n' \
            "$after_marked" "$after_unmarked" >&2
        failures=$((failures + 1))
    fi

    # Remove the samples here instead of relying on the EXIT trap and prove
    # that they are gone; the raw match records are removed by the trap as well.
    rm -rf "$tmp"
    TMP_SAMPLES=
    if [ -e "$tmp" ]; then
        printf 'self-test: FAIL: sample directory %s was not removed\n' "$tmp" >&2
        failures=$((failures + 1))
    else
        printf 'self-test: ok: sample directory removed\n'
    fi

    if [ "$failures" -ne 0 ]; then
        printf 'self-test: FAILED (%s failure(s))\n' "$failures" >&2
        return 1
    fi
    printf 'self-test: PASS (all rules fired, suppression verified, samples cleaned up)\n'
    return 0
}

# --- entry point -----------------------------------------------------------

if [ "$#" -eq 0 ]; then
    if scan_repository; then
        report_suppressed
        printf 'scan-secrets: FAIL: matches listed above\n' >&2
        exit 1
    else
        status=$?
    fi
    if [ "$status" -ne 1 ]; then
        exit "$status"
    fi
    report_suppressed
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
    status=0
    scan_file "$path" || status=$?
    case $status in
        0) found=1 ;;
        1) : ;;
        *)
            printf 'scan-secrets: error: scanning %s failed with status %s\n' "$path" "$status" >&2
            exit 2
            ;;
    esac
done

report_suppressed
if [ "$found" -ne 0 ]; then
    printf 'scan-secrets: FAIL: matches listed above\n' >&2
    exit 1
fi
printf 'scan-secrets: PASS (no matches)\n'
exit 0
