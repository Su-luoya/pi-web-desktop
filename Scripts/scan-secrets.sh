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
#   Scripts/scan-secrets.sh                 # scan every git-tracked file; refuse
#                                           #   to report a pass while untracked
#                                           #   files exist
#   Scripts/scan-secrets.sh --include-untracked
#                                           # also scan untracked, non-ignored
#                                           #   files in place (local triage)
#   Scripts/scan-secrets.sh FILE [FILE...]  # scan explicit files
#   Scripts/scan-secrets.sh --self-test     # prove every rule fires, in a temp dir
#
# Untracked-file gate: `git grep` reads tracked content only, so a new file
# that has not been `git add`ed is invisible and a local run could report a
# clean work tree that was never scanned (security review R-11). The default
# repository scan therefore refuses to run (exit 3) while untracked, non-ignored
# files exist, and prints both how to stage them and the explicit escape hatch.
# `--include-untracked` scans those files in place and is meant for local
# triage only: a file that is never added is never scanned by CI. Explicit FILE
# arguments are unaffected, because scanning named files never claimed to cover
# the work tree.
#
# Exit codes: 0 = no matches, 1 = at least one match, 2 = usage/environment
# error, 3 = untracked files present, so the repository scan refused to run
# (see the untracked-file gate above).
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

# --- untracked files -------------------------------------------------------

# How many untracked paths the refusal message lists before summarizing.
UNTRACKED_PREVIEW_LIMIT=5

# untracked_repository_files: print the untracked files that are not ignored by
# .gitignore, one path relative to the repository root per line. `git grep`
# never sees these files, so the default scan has to decide about them
# explicitly instead of silently scanning a subset of the work tree.
untracked_repository_files() {
    git -C "$ROOT" -c core.quotePath=false ls-files --others --exclude-standard
}

# report_untracked_refusal LIST_FILE COUNT: the readable message for the default
# repository scan while untracked files exist. It names the files (bounded, so
# a large untracked tree cannot flood the log) and then both ways forward.
report_untracked_refusal() {
    untracked_list=$1
    untracked_total=$2
    printf 'scan-secrets: error: %s untracked file(s) exist, so this scan cannot claim the work tree is clean\n' \
        "$untracked_total" >&2
    untracked_shown=0
    while IFS= read -r untracked_path && [ "$untracked_shown" -lt "$UNTRACKED_PREVIEW_LIMIT" ]; do
        printf 'scan-secrets:   %s\n' "$untracked_path" >&2
        untracked_shown=$((untracked_shown + 1))
    done < "$untracked_list"
    if [ "$untracked_total" -gt "$untracked_shown" ]; then
        printf 'scan-secrets:   ... and %s more\n' "$((untracked_total - untracked_shown))" >&2
    fi
    printf 'scan-secrets: hint: run `git add <path>` so the file is tracked and scanned,\n' >&2
    printf 'scan-secrets:       or re-run with --include-untracked to scan untracked files in place.\n' >&2
    printf 'scan-secrets:       A file that is never added is never scanned by CI either.\n' >&2
}

# scan_untracked_files LIST_FILE: print `<path>:<line>:<text>` records for the
# untracked files in LIST_FILE, in the same shape `git grep -n` produces so
# filter_hits parses them identically. It runs with the repository root as the
# working directory on purpose: the printed paths stay repository-relative, so
# the output never carries the local absolute path of the work tree. Binary
# files are skipped with -I, as `git grep` does. Returns 0 when every file was
# read and 2 when at least one file could not be scanned.
scan_untracked_files() {
    untracked_list=$1
    untracked_failures=0
    while IFS= read -r untracked_path; do
        [ -n "$untracked_path" ] || continue
        untracked_status=0
        (cd "$ROOT" && grep -HnIE -e "$RULE_ALL" -- "$untracked_path") || untracked_status=$?
        case $untracked_status in
            0|1) : ;;
            *)
                printf 'scan-secrets: error: grep failed for untracked file %s (status %s)\n' \
                    "$untracked_path" "$untracked_status" >&2
                untracked_failures=$((untracked_failures + 1))
                ;;
        esac
    done < "$untracked_list"
    [ "$untracked_failures" -eq 0 ] || return 2
    return 0
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

# scan_repository INCLUDE_UNTRACKED: `git grep` over every tracked file, plus
# the untracked, non-ignored files when INCLUDE_UNTRACKED is 1. Returns 0 when
# nothing was printed, 1 when at least one match was printed, 2 when the scan
# itself could not run, and 3 when untracked files exist and INCLUDE_UNTRACKED
# is 0. The refusal is deliberate: a pass here would claim coverage the scan
# does not have (security review R-11).
scan_repository() {
    include_untracked=$1
    if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'scan-secrets: error: %s is not a git work tree\n' "$ROOT" >&2
        return 2
    fi
    ensure_scan_tmp

    untracked_list="$TMP_SCAN/untracked-files"
    if ! untracked_repository_files > "$untracked_list"; then
        printf 'scan-secrets: error: git ls-files failed, cannot check for untracked files\n' >&2
        return 2
    fi
    untracked_total=$(wc -l < "$untracked_list" | tr -d '[:space:]')
    if [ "$untracked_total" -gt 0 ]; then
        if [ "$include_untracked" -eq 0 ]; then
            report_untracked_refusal "$untracked_list" "$untracked_total"
            return 3
        fi
        printf 'scan-secrets: note: --include-untracked: also scanning %s untracked file(s)\n' \
            "$untracked_total"
    fi

    records="$TMP_SCAN/repository-matches"
    : > "$records"
    grep_status=0
    git -C "$ROOT" grep -nIE -e "$RULE_ALL" -- . > "$records" || grep_status=$?
    case $grep_status in
        0|1) : ;;
        *)
            printf 'scan-secrets: error: git grep failed with status %s\n' "$grep_status" >&2
            return 2
            ;;
    esac

    if [ "$include_untracked" -eq 1 ]; then
        untracked_scan_status=0
        scan_untracked_files "$untracked_list" >> "$records" || untracked_scan_status=$?
        if [ "$untracked_scan_status" -ne 0 ]; then
            return 2
        fi
    fi

    filter_status=0
    filter_hits "$records" || filter_status=$?
    case $filter_status in
        0) return 1 ;;
        1) return 0 ;;
        *)
            printf 'scan-secrets: error: filtering match records failed with status %s\n' \
                "$filter_status" >&2
            return 2
            ;;
    esac
}

usage() {
    cat <<'USAGE'
Usage: Scripts/scan-secrets.sh [--include-untracked]
       Scripts/scan-secrets.sh FILE [FILE...]
       Scripts/scan-secrets.sh --self-test

Without arguments every git-tracked file is scanned. Untracked means "not
tracked and not ignored by .gitignore": when such files exist the default scan
refuses to run and exits 3 instead of reporting a clean work tree that was
never scanned. The refusal lists the first few paths and explains both ways
forward: run `git add <path>` so the file is tracked and scanned, or pass
--include-untracked to scan the untracked files in place for local triage. A
file only ever scanned through --include-untracked is never scanned by CI, so
stage it before relying on that result.

Explicit FILE arguments are scanned as given, tracked or not, and are useful
for checking a candidate file before it is committed; they are deliberately
not gated on the untracked state of the rest of the work tree.

Exit codes: 0 = no matches; 1 = at least one match; 2 = usage or environment
error; 3 = untracked files exist, so the repository scan refused to run.

A matched line is skipped only when that same line contains
`scan-secrets: allow`; every scan that actually runs ends with
`scan-secrets: suppressed N lines` (a refusal exits before scanning and prints
no counter). --self-test writes sample files into a temporary directory outside
the repository, asserts that each rule fires there, asserts that harmless
sample text is not reported, asserts that the inline marker suppresses exactly
its own line and is counted correctly, then builds a throwaway Git repository
(it therefore needs git) to prove the untracked-file gate: refusal by default,
detection with --include-untracked, and unchanged behavior without untracked
files. Both temporary directories are removed again.
USAGE
}

# --- self-test -------------------------------------------------------------

# self_test_untracked_gate SAMPLE_DIR: prove the untracked-file gate with a
# throwaway Git repository inside SAMPLE_DIR (already outside the work tree, so
# no repository state is touched). The scanner is copied into that repository
# so the copy resolves its own ROOT there; every case runs the copy as a
# subprocess and asserts its exit code and output. This is the only part of
# --self-test that needs git.
self_test_untracked_gate() {
    gate_samples=$1
    gate_repo="$gate_samples/untracked-repo"
    gate_status=0
    gate_output=''

    if ! mkdir -p "$gate_repo/Scripts"; then
        printf 'self-test: FAIL: cannot create the untracked-gate repository under %s\n' \
            "$gate_samples" >&2
        failures=$((failures + 1))
        return
    fi
    if ! cp "$SCRIPT_DIR/scan-secrets.sh" "$gate_repo/Scripts/scan-secrets.sh"; then
        printf 'self-test: FAIL: cannot copy the scanner into the untracked-gate repository\n' >&2
        failures=$((failures + 1))
        return
    fi

    # One tracked file and one ignored file: the ignored file must not count as
    # untracked, because the gate excludes paths covered by .gitignore. The
    # empty excludes file is a local override so a contributor's global
    # core.excludesFile cannot hide the sample files from the gate.
    printf 'ignored.txt\n' > "$gate_repo/.gitignore"
    printf 'ordinary tracked content\n' > "$gate_repo/tracked.txt"
    printf 'local scratch content is ignored\n' > "$gate_repo/ignored.txt"
    printf '' > "$gate_samples/untracked-gate-empty-excludes"

    if ! git -C "$gate_repo" init -q \
        || ! git -C "$gate_repo" config core.excludesFile "$gate_samples/untracked-gate-empty-excludes" \
        || ! git -C "$gate_repo" add -A; then
        printf 'self-test: FAIL: cannot initialise the untracked-gate repository\n' >&2
        failures=$((failures + 1))
        return
    fi

    run_gate_scan() {
        gate_status=0
        gate_output=$(CDPATH= cd -- "$gate_repo" && sh ./Scripts/scan-secrets.sh "$@" 2>&1) || gate_status=$?
    }

    expect_gate_status() {
        expect_status=$1
        expect_label=$2
        if [ "$gate_status" -eq "$expect_status" ]; then
            printf 'self-test: ok: %s (exit %s)\n' "$expect_label" "$gate_status"
        else
            printf 'self-test: FAIL: %s: exit %s, expected %s\n' \
                "$expect_label" "$gate_status" "$expect_status" >&2
            printf '%s\n' "$gate_output" | sed 's/^/     /' >&2
            failures=$((failures + 1))
        fi
    }

    expect_gate_output() {
        expect_needle=$1
        expect_label=$2
        case $gate_output in
            *"$expect_needle"*)
                printf 'self-test: ok: %s\n' "$expect_label"
                ;;
            *)
                printf 'self-test: FAIL: %s: output does not mention %s\n' \
                    "$expect_label" "$expect_needle" >&2
                printf '%s\n' "$gate_output" | sed 's/^/     /' >&2
                failures=$((failures + 1))
                ;;
        esac
    }

    # Case 1: no untracked file (the ignored one does not count) -- the default
    # scan keeps its previous behavior and reports the covered scope.
    run_gate_scan
    expect_gate_status 0 "no untracked files: the default scan still passes"
    expect_gate_output 'scan-secrets: PASS (no matches in tracked files; no untracked files)' \
        "no untracked files: the PASS line names the covered scope"
    expect_gate_output 'scan-secrets: suppressed 0 lines' \
        "no untracked files: the suppression summary is printed"

    # Case 2: a sample credential in an untracked file blocks the default scan.
    gate_untracked_credential='ghp_'"0123456789abcdefghijABCDEFGHIJ"
    printf 'leaked: %s\n' "$gate_untracked_credential" > "$gate_repo/untracked-leak.txt"
    run_gate_scan
    expect_gate_status 3 "an untracked file makes the default scan refuse (exit 3)"
    expect_gate_output 'untracked-leak.txt' "the refusal names the untracked file"
    expect_gate_output 'git add' "the refusal explains how to stage the file"
    expect_gate_output '--include-untracked' "the refusal names the explicit escape hatch"

    # Case 3: the switch scans the untracked file and reports its credential.
    run_gate_scan --include-untracked
    expect_gate_status 1 "--include-untracked reports the untracked credential"
    expect_gate_output 'untracked-leak.txt:1:' \
        "--include-untracked reports the untracked file and line"

    # Case 4: explicit FILE arguments stay independent of untracked files.
    run_gate_scan tracked.txt
    expect_gate_status 0 "explicit FILE mode ignores untracked files elsewhere"
    run_gate_scan untracked-leak.txt
    expect_gate_status 1 "an untracked file can always be checked by naming it"

    # Case 5: mixing the switch with explicit files is a usage error.
    run_gate_scan --include-untracked tracked.txt
    expect_gate_status 2 "--include-untracked with explicit FILE arguments is a usage error"

    # Case 6: staged content is still detected by the default scan.
    if git -C "$gate_repo" add untracked-leak.txt; then
        run_gate_scan
        expect_gate_status 1 "the same credential is reported once the file is staged"
        expect_gate_output 'untracked-leak.txt:1:' "the staged file is reported with its line"
    else
        printf 'self-test: FAIL: cannot stage the sample file in the untracked-gate repository\n' >&2
        failures=$((failures + 1))
    fi

    # Case 7: a clean tree passes with the switch too -- the switch only widens
    # the scanned set, it does not change the rules.
    if git -C "$gate_repo" rm --cached -q untracked-leak.txt; then
        rm -f "$gate_repo/untracked-leak.txt"
        run_gate_scan --include-untracked
        expect_gate_status 0 "--include-untracked on a clean tree passes"
    else
        printf 'self-test: FAIL: cannot unstage the sample file in the untracked-gate repository\n' >&2
        failures=$((failures + 1))
    fi

    # The gate is only usable when its contract is discoverable, so --help must
    # document both the switch and the new exit code.
    run_gate_scan --help
    expect_gate_status 0 "--help exits 0"
    expect_gate_output '--include-untracked' "--help documents the untracked switch"
    expect_gate_output '3 = untracked files exist' "--help documents exit code 3"
}

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

    # The untracked-file gate is a contract of the entry point (options, exit
    # codes, output), so exercise it against a throwaway repository instead of
    # calling an internal helper.
    self_test_untracked_gate "$tmp"

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
    printf 'self-test: PASS (all rules fired, suppression verified, untracked-file gate verified, samples cleaned up)\n'
    return 0
}

# --- entry point -----------------------------------------------------------

INCLUDE_UNTRACKED=0
SELF_TEST=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --help|-h)
            usage
            exit 0
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        --include-untracked)
            INCLUDE_UNTRACKED=1
            shift
            ;;
        -*)
            printf 'scan-secrets: error: unknown option %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

if [ "$SELF_TEST" -eq 1 ]; then
    if [ "$#" -ne 0 ]; then
        printf 'scan-secrets: error: --self-test takes no further arguments\n' >&2
        exit 2
    fi
    if [ "$INCLUDE_UNTRACKED" -ne 0 ]; then
        printf 'scan-secrets: error: --include-untracked applies to the repository scan, not to --self-test\n' >&2
        exit 2
    fi
    self_test
    exit $?
fi

if [ "$#" -eq 0 ]; then
    status=0
    scan_repository "$INCLUDE_UNTRACKED" || status=$?
    case $status in
        0)
            report_suppressed
            if [ "$INCLUDE_UNTRACKED" -eq 1 ]; then
                printf 'scan-secrets: PASS (no matches in tracked or untracked files)\n'
            else
                printf 'scan-secrets: PASS (no matches in tracked files; no untracked files)\n'
            fi
            exit 0
            ;;
        1)
            report_suppressed
            printf 'scan-secrets: FAIL: matches listed above\n' >&2
            exit 1
            ;;
        *)
            exit "$status"
            ;;
    esac
fi

if [ "$INCLUDE_UNTRACKED" -ne 0 ]; then
    printf 'scan-secrets: error: --include-untracked cannot be combined with explicit FILE arguments (named files are scanned whether or not they are tracked)\n' >&2
    exit 2
fi

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
