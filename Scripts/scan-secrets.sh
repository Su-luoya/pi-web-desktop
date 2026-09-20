#!/bin/sh
# scan-secrets.sh - repository secret scan (GitHub #11, expanded in #75).
#
# Scope: high-signal credential shapes a reviewer can act on immediately.
#
# Structural shapes (a prefix that practically only a credential has):
#   * AWS access key IDs: `AKIA` or the temporary-credential `ASIA` plus 16
#     uppercase letters/digits.
#   * GitHub tokens: `ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_` plus a long body, and
#     fine-grained `github_pat_` tokens.
#   * Slack tokens: `xoxb-`/`xoxp-` and the other `xox<letter>-` families.
#   * Stripe keys `sk_live_`/`sk_test_`/`rk_live_`/`rk_test_`, and the
#     `sk-proj-`/`sk-ant-`/`sk-or-`/`sk-` families used by API providers.
#   * age secret keys (`AGE-SECRET-KEY-1` plus a base32 body).
#   * PEM/OpenSSH/SSH2 private key headers, including the PGP block form.
#   * JWTs (`eyJ` plus three base64url segments).
#   * `Authorization: Bearer <token>` headers.
#   * a credential inside a connection string
#     (`scheme://user` + `:` + password + `@` + host), e.g. a `DATABASE_URL`.
#
# Key/value shapes (config assignments; the key is matched case-insensitively):
#   * `password`, `passwd`, `passphrase`, `secret`, `token`, `apikey`,
#     `api_key`, `private_key`, `access_key`, `credential`, with arbitrary
#     `[A-Za-z0-9_-]` prefixes and suffixes so `AWS_SECRET_ACCESS_KEY`,
#     `DB_PASSWORD` and `SLACK_BOT_TOKEN` are covered by the same rule;
#   * the key must sit at a configuration position: start of line (including an
#     indent), directly after `{` (JSON object/TOML inline table), directly
#     after `,` for a quoted key (JSON object member), or after a leading
#     `export`/`ENV`/`ARG`/`declare`;
#   * the key may be quoted (`"password": "…"`) and the separator may be `:` or
#     `=` with any amount of horizontal whitespace on either side, which covers
#     the JSON, YAML, TOML, INI and `.env` spellings;
#   * the value must be a literal of at least 12 characters: either a quoted
#     printable-ASCII string (a value with spaces is fine there) or an unquoted
#     run of `A-Za-z0-9_+/%@$&!?~-` that ends at a non-value character;
#   * the Chinese key names `密码`, `口令`, `密钥`, `私钥`, `令牌` and `凭据` are
#     reported with the same value rules (a value made of Chinese text alone is
#     still not a literal this rule can vouch for, so it is not reported).
#
# Deliberately NOT reported (look-alikes the rules above would otherwise catch):
#   * placeholder and template values, e.g. a `token=YOUR_TOKEN_HERE` sample in
#     documentation, `password: <redacted>`, `api_key = "REPLACE_ME"`, `...`,
#     `${VAR}` or `$((...))`;
#   * credentials in documentation hosts: RFC 2606/6761 reserved names
#     (`.invalid`, `.test`, `.example`, `.local`, `localhost`), the reserved
#     `example.com`/`example.net`/`example.org` domains, and dotless
#     single-label hosts, as used by the redaction fixtures and proxy examples
#     in this repository;
#   * unquoted camelCase identifiers such as `password: effectivePassword` or
#     `remoteAccessPassword: RemoteAccessPassword.statusText(…)`, which are code
#     parameters and not config literals.
#
# Out of scope (this is not a general secret scanner): free prose with no key,
# high-entropy strings that carry no recognizable key or prefix, binary and
# encrypted payloads (`-I` skips binary files), Git history, values that are not
# ASCII literals, and credentials embedded in a Swift/SQL string literal that is
# not at a configuration position. The rules are fixed regexes, so a credential
# that does not match one of these shapes is not reported. It is a complement
# to, not a replacement for, review and the personal-data scan. The boundary is
# documented in docs/development.md ("personal-data 与 secret 扫描能力").
#
# Inline suppression: a matched line is skipped only when that same line also
# carries `scan-secrets: allow(reason=…)` with a reason of at least 8
# characters. The marker exists for lines whose text is deliberately
# credential-shaped sample data (redaction test fixtures); it must not be used to
# mute a real finding, and it never exempts a whole file or directory. The old
# bare `scan-secrets: allow` form is not a suppression any more: the line is
# reported and the run prints a warning naming the file and line. Every run ends
# with `scan-secrets: suppressed N lines`, suppressed lines are printed with a
# `scan-secrets: suppressed:` prefix (so the muted text stays visible), and a run
# whose markers are missing or too short also prints a `rejected M suppression
# markers` summary before failing. `--self-test` asserts all of this.
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

# A matched line is skipped only when the matched line itself carries a reason:
#
#     scan-secrets: allow(reason=<text>)
#
# The reason must be at least SUPPRESS_REASON_MIN characters long after trimming
# leading/trailing whitespace. The check is per line on purpose: there is no
# file, directory or pathspec exemption anywhere in this script. A line that
# carries the old bare marker is not suppressed: it is reported as a finding and
# the run prints a warning that names it, so no marker can mute a credential
# silently (GitHub #75).
SUPPRESS_MARKER='scan-secrets: allow'
SUPPRESS_FORM='scan-secrets: allow(reason=<at least 8 characters>)'
SUPPRESS_REASON_MIN=8

# --- rules -----------------------------------------------------------------

# fold_alternation WORDS: print a POSIX ERE alternation that matches every word
# in the space-separated list in any letter case. `grep` has no inline `(?i)`
# flag and making the whole pattern case-insensitive would silently lower the
# precision of the structural rules (an `AKIA`-shaped rule would start matching
# `akia`), so only the key words of the key/value rule are folded, and they are
# folded at run time: the resulting pattern never appears in this file.
fold_alternation() {
    printf '%s' "$1" | awk '
        {
            count = split($0, words, /[ \t]+/)
            for (word = 1; word <= count; word++) {
                if (word > 1) printf "|"
                for (i = 1; i <= length(words[word]); i++) {
                    character = substr(words[word], i, 1)
                    lower = tolower(character)
                    upper = toupper(character)
                    if (lower == upper) printf "%s", character
                    else printf "[%s%s]", lower, upper
                }
            }
        }'
}

# Key words of the key/value rule (English) and the Chinese key names that are
# reported too. Chinese names are matched literally: they are their own case,
# and a byte-exact literal works in both ASCII and UTF-8 locales.
KV_WORDS='password passwd passphrase secret token apikey api_key private_key access_key credential'
KV_WORDS_CJK='密码|口令|密钥|私钥|令牌|凭据'
KV_KEYWORDS="$(fold_alternation "$KV_WORDS")|$KV_WORDS_CJK"

# A key token: the whole `[A-Za-z0-9_-]` run that contains a key word, so a
# prefixed/suffixed environment variable name is one key. A quoted key is the
# JSON spelling `"password"`; the quotes are part of the pattern so a quoted
# string that happens to contain an assignment is not treated as a bare key.
KV_KEY_BARE="[A-Za-z0-9_-]*($KV_KEYWORDS)[A-Za-z0-9_-]*"

# Configuration positions. `$1` matches "start of the scanned text" (a line
# inside a file, or a record inside the match list), so the key/value rule and
# the look-alike filters below can share one notion of "config assignment".
# The `,` position is only offered to quoted keys: it is the JSON object member
# spelling, and it is also how a Swift dictionary literal looks, which is the
# main source of look-alikes in this repository.
kv_position() {
    start=$1
    printf '((%s|[{][[:blank:]]*|(export|ENV|ARG|declare)[[:blank:]]+)%s' \
        "$start" "$KV_KEY_BARE"
    printf "|(%s|[{,][[:blank:]]*|(export|ENV|ARG|declare)[[:blank:]]+)[\"']%s[\"'])" \
        "$start" "$KV_KEY_BARE"
}

# Line start in a scanned file, and line start inside a `<path>:<line>:<text>`
# record as produced by `git grep -n` / `grep -Hn`.
FILE_POSITION='^[[:blank:]]*'
RECORD_POSITION='^[^:]*:[0-9]+:[[:blank:]]*'

KV_SEPARATOR='[[:blank:]]*[:=][[:blank:]]*'
# Bare values: at least 12 characters from the config-value vocabulary, ending at
# a character outside it (so `scheduler.repeating` never reaches 12 characters).
VALUE_CHARS='A-Za-z0-9_+/%@$&!?~-'
KV_VALUE="[$VALUE_CHARS]{12,}([^$VALUE_CHARS]|\$)"
# Quoted values: at least 12 printable ASCII characters, which accepts spaces
# (`PASSWORD="p@ss w0rd with spaces"`) but not a value made of non-ASCII text.
PRINTABLE_CHARS=' -~'
KV_VALUE_QUOTED="\"[$PRINTABLE_CHARS]{12,}\"|'[$PRINTABLE_CHARS]{12,}'"

# Key/value rule: configuration position, key, separator, literal value.
RULE_KEY_VALUE="$(kv_position "$FILE_POSITION")$KV_SEPARATOR($KV_VALUE_QUOTED|$KV_VALUE)"

# AWS access key ID (both the long-lived `AKIA` and temporary `ASIA` prefixes;
# AWS key IDs are always 4 prefix letters plus 16 uppercase alphanumerics).
RULE_AWS='(AKIA|ASIA)[0-9A-Z]{16}'

# GitHub tokens: `gh[pousr]_` plus a long body, and `github_pat_` separately
# because its body class allows underscores.
RULE_GITHUB='gh[pousr]_[A-Za-z0-9]{20,}'
RULE_GITHUB_PAT='github_pat_[A-Za-z0-9_]{20,}'

# Slack tokens: `xoxb-`/`xoxp-` and the sibling families, which are a prefix plus
# a hyphenated body.
RULE_SLACK='xox[abporcs]-[0-9A-Za-z-]{20,}'

# Stripe secret/restricted keys (`sk_live_`/`sk_test_`/`rk_live_`/`rk_test_`) and
# the provider keys that use a hyphenated prefix (`sk-proj-`, `sk-ant-`,
# `sk-or-`) or the legacy `sk-` plus a long body.
RULE_STRIPE='(sk|rk)_(live|test)_[0-9A-Za-z]{16,}'
RULE_PROVIDER='(sk-(proj|ant|or)-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,})'

# age secret keys: a fixed prefix plus a long base32 body.
RULE_AGE='AGE-SECRET-KEY-1[0-9A-Z]{40,}'

# Private key headers (RSA/EC/OPENSSH/DSA, the SSH2 `ENCRYPTED` form, whose label
# contains a digit, and the PGP block form).
RULE_PEM='-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----'

# JWT: header.payload.signature, each segment at least 8 base64url characters.
RULE_JWT='eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'

# `Authorization: Bearer <token>` with a 20+ character token, which is short
# enough for real opaque tokens and long enough that prose mentioning a bearer
# token (`Bearer <token>`) is not reported.
RULE_BEARER="$(fold_alternation 'authorization')[[:blank:]]*:[[:blank:]]*$(fold_alternation 'bearer')[[:blank:]]+[A-Za-z0-9._~+/-]{20,}"

# A credential inside a connection string: `scheme://user:password@host`. A URL
# without a password (`scheme://user@host`) and a scheme-less `user:password@`
# are not reported.
RULE_CONNECTION_STRING='[A-Za-z][A-Za-z0-9+.-]*://[^/?#@[:space:]:]+:[^/?#@[:space:]]+@'

RULE_ALL="$RULE_AWS|$RULE_GITHUB|$RULE_GITHUB_PAT|$RULE_SLACK|$RULE_STRIPE|$RULE_PROVIDER|$RULE_AGE|$RULE_PEM|$RULE_JWT|$RULE_BEARER|$RULE_CONNECTION_STRING|$RULE_KEY_VALUE"

# --- look-alike filters ------------------------------------------------------

# Filters that drop a match whose *text* is a documented look-alike rather than
# a credential. They run on the raw `<path>:<line>:<text>` records, so their
# "start of line" fragment is RECORD_POSITION instead of FILE_POSITION.
#
# The filters are deliberately narrow, and each one is also a documented
# limitation: a line that mixes a real credential with a placeholder assignment
# on the same line can be dropped as a whole, which is why both the rules and
# the filters are asserted by --self-test.

# A placeholder value: a template marker (`<redacted>`, `${VAR}`, `$(...)`,
# `{...}`), an ellipsis, or one of the words that documentation and sample data
# use for "put your value here". The word must be the start of the value and
# must not continue into an identifier, so `your-token` is a placeholder while
# `yourToken1234` is still reported; a sample password such as `hunter2` is not
# on the list, because `--self-test` requires a line like
# `DB_PASSWORD=hunter2-should-be-caught` to be reported.
PLACEHOLDER_WORDS='your|my|the|some|example|sample|dummy|fake|placeholder|changeme|change_me|redacted|redact|replace|insert|todo|xxxx|yyyy|zzzz|foo|bar|baz|password|passphrase'
RULE_LOOK_ALIKE_VALUE="($(kv_position "$RECORD_POSITION")$KV_SEPARATOR[\"']?((($PLACEHOLDER_WORDS)[^A-Za-z]|\.\.\.|[<{][({]?|[$][({]))|://[^/?#@[:space:]]*[<{$][^/?#@[:space:]]*@)"

# A documentation host: a reserved name (RFC 2606/6761), a reserved
# `example.com`/`example.net`/`example.org` domain, or a dotless single-label
# host such as `localhost` or `host` in a docs sample.
RULE_LOOK_ALIKE_HOST='://[^/?#@[:space:]]+@(([A-Za-z0-9-]+\.)*(invalid|test|example|local|localhost)|example\.(com|net|org))([^A-Za-z0-9-]|$)|://[^/?#@[:space:]]+@[A-Za-z]+([^A-Za-z0-9.-]|$)'

# An unquoted camelCase value such as `password: effectivePassword`: a code
# identifier, not a config literal. `--self-test` pins that quoting the value
# (`"MySecretPassword"`) keeps it reported.
RULE_LOOK_ALIKE_IDENTIFIER="$(kv_position "$RECORD_POSITION")$KV_SEPARATOR[A-Za-z]*[a-z][A-Z][A-Za-z]*([^$VALUE_CHARS]|\$)"

# drop_look_alikes IN_FILE OUT_FILE: copy the `<path>:<line>:<text>` records in
# IN_FILE to OUT_FILE, dropping the records whose text is a documented
# look-alike. Each filter runs as its own command so that a malformed pattern
# fails the scan with status 2 instead of silently dropping nothing. Returns 0
# when the filters ran and 2 when one of them failed.
drop_look_alikes() {
    drop_input=$1
    drop_output=$2
    drop_stage="$drop_output.stage"
    drop_status=0

    grep -viE -e "$RULE_LOOK_ALIKE_VALUE" -- "$drop_input" > "$drop_stage" || drop_status=$?
    if [ "$drop_status" -gt 1 ]; then
        printf 'scan-secrets: error: filtering placeholder values failed with status %s\n' \
            "$drop_status" >&2
        return 2
    fi

    grep -viE -e "$RULE_LOOK_ALIKE_HOST" -- "$drop_stage" > "$drop_output" || drop_status=$?
    if [ "$drop_status" -gt 1 ]; then
        printf 'scan-secrets: error: filtering documentation hosts failed with status %s\n' \
            "$drop_status" >&2
        return 2
    fi

    grep -vE -e "$RULE_LOOK_ALIKE_IDENTIFIER" -- "$drop_output" > "$drop_stage" || drop_status=$?
    if [ "$drop_status" -gt 1 ]; then
        printf 'scan-secrets: error: filtering identifier values failed with status %s\n' \
            "$drop_status" >&2
        return 2
    fi

    mv "$drop_stage" "$drop_output"
    return 0
}

# --- scratch space -----------------------------------------------------------

# Scratch directories are created outside $ROOT so neither the repository scan
# nor --self-test ever writes into the work tree. `cleanup` removes whatever
# exists, also when the scan exits through an error path.
TMP_SAMPLES=
TMP_SCAN=
SUPPRESSED_COUNT=
REJECTED_COUNT=

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
# first use and point the suppression counters at the counter files inside it.
ensure_scan_tmp() {
    if [ -z "$TMP_SCAN" ]; then
        TMP_SCAN=$(make_temp_dir)
        SUPPRESSED_COUNT="$TMP_SCAN/suppressed.count"
        REJECTED_COUNT="$TMP_SCAN/rejected.count"
    fi
}

# count_file FILE: print the number stored in FILE, or 0 when it does not exist.
count_file() {
    if [ -n "$1" ] && [ -f "$1" ]; then
        cat "$1"
    else
        printf '0\n'
    fi
}

# suppressed_count / rejected_count: the numbers behind the end-of-run summary.
suppressed_count() {
    count_file "$SUPPRESSED_COUNT"
}

rejected_count() {
    count_file "$REJECTED_COUNT"
}

# report_suppression_summary: the end-of-run summary that keeps suppression
# auditable. The suppressed count is always printed; the rejected count is only
# printed when a marker was missing a usable reason, because that case always
# also fails the run.
report_suppression_summary() {
    printf 'scan-secrets: suppressed %s lines\n' "$(suppressed_count)"
    rejected_total=$(rejected_count)
    if [ "$rejected_total" -gt 0 ]; then
        printf 'scan-secrets: rejected %s suppression marker(s) without a reason of at least %s characters\n' \
            "$rejected_total" "$SUPPRESS_REASON_MIN"
    fi
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

# filter_hits RECORD_FILE: print the records that are findings, print the
# records that a valid suppression marker mutes (prefixed with
# `scan-secrets: suppressed:`, so the muted text stays visible), and count both
# kinds in the counter files. A record has the `<path>:<line>:<text>` shape
# produced by `git grep -n` and `grep -Hn`, so only the matched line itself
# decides whether a marker applies; a marker elsewhere in the same file does
# not. A record whose prefix cannot be parsed (for example a path containing
# `:`) is reported rather than suppressed, because the scanner must fail loudly
# instead of hiding a finding. A marker that is not the
# `scan-secrets: allow(reason=…)` form, or whose reason is shorter than
# SUPPRESS_REASON_MIN characters, is reported as a finding and warned about.
# Returns 0 when at least one finding was printed, 1 otherwise.
filter_hits() {
    awk -v suppressed_counter="$SUPPRESSED_COUNT" \
        -v rejected_counter="$REJECTED_COUNT" \
        -v minimum_reason="$SUPPRESS_REASON_MIN" '
        {
            content = ""
            if (match($0, /^[^:]*:[0-9]+:/)) {
                content = substr($0, RSTART + RLENGTH)
            }
            if (content != "") {
                if (match(content, /scan-secrets:[ \t]*allow[ \t]*\([ \t]*reason[ \t]*=[^)]*\)/)) {
                    reason = substr(content, RSTART, RLENGTH)
                    sub(/^[^=]*=[ \t]*/, "", reason)
                    sub(/\)$/, "", reason)
                    sub(/[ \t]+$/, "", reason)
                    if (length(reason) >= minimum_reason) {
                        suppressed++
                        printf "scan-secrets: suppressed: %s\n", $0
                        next
                    }
                }
                if (index(content, "scan-secrets:") > 0 && index(content, "allow") > 0) {
                    rejected++
                    printf "scan-secrets: warning: %s: suppression marker without a usable reason; write `scan-secrets: allow(reason=<at least %d characters>)`\n", $0, minimum_reason > "/dev/stderr"
                }
            }
            print
            printed++
        }
        END {
            append_count(suppressed_counter, suppressed)
            append_count(rejected_counter, rejected)
            exit (printed > 0 ? 0 : 1)
        }
        function append_count(file, amount) {
            if (amount > 0 && file != "") {
                base = 0
                if ((getline previous < file) > 0) base = previous + 0
                close(file)
                printf "%d\n", base + amount > file
                close(file)
            }
        }
    ' "$1"
}

# filter_matches RECORD_FILE: apply the look-alike filters and then the
# suppression filter, so suppressed and rejected accounting only ever sees
# records that survived the look-alike filters. Returns 0 when at least one
# finding was printed, 1 when the records were clean, 2 when filtering failed.
filter_matches() {
    records=$1
    filtered="$TMP_SCAN/look-alike-filtered"
    look_status=0
    drop_look_alikes "$records" "$filtered" || look_status=$?
    if [ "$look_status" -ne 0 ]; then
        return 2
    fi
    filter_status=0
    filter_hits "$filtered" || filter_status=$?
    case $filter_status in
        0|1) return "$filter_status" ;;
        *)
            printf 'scan-secrets: error: filtering match records failed with status %s\n' \
                "$filter_status" >&2
            return 2
            ;;
    esac
}

# scan_file FILE: print the findings (and suppressed hits); 0 = at least one
# finding printed, 1 = clean or fully suppressed, 2 = the file could not be
# scanned.
scan_file() {
    ensure_scan_tmp
    records="$TMP_SCAN/file-matches"
    status=0
    grep -HnIE -e "$RULE_ALL" -- "$1" > "$records" || status=$?
    case $status in
        0) filter_matches "$records" ;;
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

    match_status=0
    filter_matches "$records" || match_status=$?
    case $match_status in
        0) return 1 ;;
        1) return 0 ;;
        *) return 2 ;;
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

The rules cover credential prefixes (AWS, GitHub, Slack, Stripe/provider keys,
age, PEM/OpenSSH/SSH2 private key headers, JWTs, Authorization: Bearer) and
key/value assignments at a configuration position (JSON, YAML, TOML, INI, .env
and `export`/`ENV` forms, English and Chinese key names, 12+ character literal
values). Free prose, high-entropy strings without a key, binary files, Git
history and non-ASCII values are out of scope; the whole boundary is documented
in docs/development.md.

A matched line is skipped only when that same line contains
`scan-secrets: allow(reason=...)` with a reason of at least 8 characters; the
older bare marker is not a suppression any more (the line is reported and a
warning names it). Suppressed lines are still printed, prefixed with
`scan-secrets: suppressed:`, and every scan that actually runs ends with
`scan-secrets: suppressed N lines` plus, when markers were missing or too
short, a `scan-secrets: rejected M suppression markers` line (a refusal exits
before scanning and prints no counter).

--self-test writes sample files into a temporary directory outside the
repository, asserts that each rule fires there, asserts that the documented
look-alikes (placeholders, documentation hosts, camelCase identifiers) are not
reported, asserts that the Chinese key names fire, asserts that a marker with a
reason suppresses exactly its own line and is counted and printed, asserts that
a bare or reason-less marker is reported and counted as rejected, then builds a
throwaway Git repository (it therefore needs git) to prove the untracked-file
gate: refusal by default, detection with --include-untracked, and unchanged
behavior without untracked files. Both temporary directories are removed again.
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

# run_sample FILE: run the scanner's own FILE mode on FILE. The scan runs in
# this shell on purpose: the scratch directory and the suppression counters are
# shell variables, and a command-substitution subshell would lose the updates.
# The combined output goes to $SAMPLE_OUTPUT, the exit status to $SAMPLE_STATUS
# (0 = finding, 1 = clean).
SAMPLE_OUTPUT=
SAMPLE_STATUS=0
run_sample() {
    SAMPLE_STATUS=0
    scan_file "$1" > "$SAMPLE_OUTPUT" 2>&1 || SAMPLE_STATUS=$?
}

# expect_hit / expect_clean LABEL FILE: assert that scanning FILE reports (or
# does not report) a finding. The output is kept for the failure message.
expect_hit() {
    label=$1
    file=$2
    run_sample "$file"
    case $SAMPLE_STATUS in
        0)
            printf 'self-test: ok: %s is detected\n' "$label"
            ;;
        1)
            printf 'self-test: FAIL: %s was not detected\n' "$label" >&2
            failures=$((failures + 1))
            ;;
        *)
            printf 'self-test: FAIL: scanning %s failed with status %s\n' "$label" "$SAMPLE_STATUS" >&2
            sed 's/^/     /' "$SAMPLE_OUTPUT" >&2
            failures=$((failures + 1))
            ;;
    esac
}

expect_clean() {
    label=$1
    file=$2
    run_sample "$file"
    case $SAMPLE_STATUS in
        1)
            printf 'self-test: ok: %s is not reported\n' "$label"
            ;;
        0)
            printf 'self-test: FAIL: %s was reported as a secret:\n' "$label" >&2
            sed 's/^/     /' "$SAMPLE_OUTPUT" >&2
            failures=$((failures + 1))
            ;;
        *)
            printf 'self-test: FAIL: scanning %s failed with status %s\n' "$label" "$SAMPLE_STATUS" >&2
            sed 's/^/     /' "$SAMPLE_OUTPUT" >&2
            failures=$((failures + 1))
            ;;
    esac
}

# expect_output_contains NEEDLE LABEL: assert that the last run_sample output
# mentions NEEDLE. expect_output_lacks is the inverse.
expect_output_contains() {
    needle=$1
    label=$2
    case $(cat "$SAMPLE_OUTPUT") in
        *"$needle"*)
            printf 'self-test: ok: %s\n' "$label"
            ;;
        *)
            printf 'self-test: FAIL: %s: output does not mention %s\n' "$label" "$needle" >&2
            sed 's/^/     /' "$SAMPLE_OUTPUT" >&2
            failures=$((failures + 1))
            ;;
    esac
}

expect_output_lacks() {
    needle=$1
    label=$2
    case $(cat "$SAMPLE_OUTPUT") in
        *"$needle"*)
            printf 'self-test: FAIL: %s: output unexpectedly mentions %s\n' "$label" "$needle" >&2
            sed 's/^/     /' "$SAMPLE_OUTPUT" >&2
            failures=$((failures + 1))
            ;;
        *)
            printf 'self-test: ok: %s\n' "$label"
            ;;
    esac
}

self_test() {
    TMP_SAMPLES=$(make_temp_dir)
    tmp=$TMP_SAMPLES
    SAMPLE_OUTPUT="$tmp/last-output"
    # Own the scratch directory and the counters here, before any nested scan,
    # so the counter files below are the ones the scans write to.
    ensure_scan_tmp

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
    sample_aws_temp='ASIA'"ABCDEFGHIJKLMNOP"
    sample_gh='gho_'"0123456789abcdefghijABCDEFGHIJ"
    sample_gh_pat='github_pat_'"11ABCDEFG0abcdefghijklmnopqrstuvwxyz234567"
    sample_slack='xoxb-'"123456789012-abcdefghijklmnop"
    sample_slack_user='xoxp-'"123456789012-abcdefghijklmnop"
    sample_stripe_live='sk_live_'"51H8xQeK9abcdefghijklmnop"
    sample_stripe_test='sk_test_'"51H8xQeK9abcdefghijklmnop"
    sample_provider='sk-proj-'"abcdefghijklmnopqrstuvwxyz123456"
    sample_age='AGE-SECRET-KEY-1'"QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
    sample_jwt=$(printf '%s.%s.%s' \
        'eyJhbGciOiJIUzI1NiJ9' 'eyJzdWIiOiIxMjM0NTY3ODkwIn0' 'c2lnbmF0dXJlLXNlY3Rpb24')
    sample_connstr=$(printf 'DATABASE_URL=postgres://appuser%s%s@db.internal:5432/prod' \
        ':' 'pg-super-secret')
    sample_upper_env=$(printf 'AWS_SECRET_ACCESS_KEY=%s' \
        'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY')
    sample_env_phrase=$(printf 'DB_PASSWORD=%s' 'correcthorsebatterystaple')
    sample_env_sample=$(printf 'DB_PASSWORD=%s' 'hunter2-should-be-caught')
    sample_env_bot=$(printf 'SLACK_BOT_TOKEN=%s' "$sample_slack")
    sample_env_key=$(printf 'SECRET_KEY=%s' '0123456789abcdef0123456789abcdef')
    sample_env_spaced=$(printf 'PASSWORD=%s' '"p@ss w0rd with spaces"')
    sample_dq='"'
    sample_json=$(printf '{ "password": %s }' "${sample_dq}json-secret-value-1234${sample_dq}")
    sample_json_camel=$(printf '{ "apiKey": %s }' "${sample_dq}json-api-key-value-5678${sample_dq}")
    sample_yaml=$(printf 'password: %s' 'yaml-secret-value')
    sample_toml=$(printf 'api_key = %s' "${sample_dq}toml-secret-value-1234${sample_dq}")
    sample_export=$(printf 'export TOKEN=%s' '0123456789abcdef0123456789abcdef')
    sample_cjk=$(printf '密码=%s' 'abcdefghijklmnop1234')
    sample_bearer=$(printf 'Authorization: Bearer %s' '8f3a1c9d2e7b4a5f6c8d0e1f2a3b4c5d6e7f8a9b')
    sample_pem='-----BEGIN RSA'" PRIVATE KEY-----"
    sample_openssh='-----BEGIN OPENSSH'" PRIVATE KEY-----"
    sample_ssh2='-----BEGIN SSH2 ENCRYPTED'" PRIVATE KEY-----"
    sample_pgp='-----BEGIN PGP'" PRIVATE KEY BLOCK-----"
    sample_mixed_value=$(printf 'api_key: %s' 'AbCdEf0123456789xyz')

    # --- rules that must fire -------------------------------------------------
    printf '%s\n' "$sample_aws" > "$tmp/aws.txt"
    printf '%s\n' "$sample_aws_temp" > "$tmp/aws_temp.txt"
    printf '%s\n' "$sample_gh" > "$tmp/github.txt"
    printf '%s\n' "$sample_gh_pat" > "$tmp/github_pat.txt"
    printf '%s\n' "$sample_slack" > "$tmp/slack.txt"
    printf '%s\n' "$sample_slack_user" > "$tmp/slack_user.txt"
    printf '%s\n' "$sample_stripe_live" > "$tmp/stripe_live.txt"
    printf '%s\n' "$sample_stripe_test" > "$tmp/stripe_test.txt"
    printf '%s\n' "$sample_provider" > "$tmp/provider.txt"
    printf '%s\n' "$sample_age" > "$tmp/age.txt"
    printf '%s\n' "$sample_jwt" > "$tmp/jwt.txt"
    printf '%s\n' "$sample_connstr" > "$tmp/connstr.txt"
    printf '%s\n' "$sample_upper_env" > "$tmp/upper_env.txt"
    printf '%s\n' "$sample_env_phrase" > "$tmp/env_phrase.txt"
    printf '%s\n' "$sample_env_sample" > "$tmp/env_sample.txt"
    printf '%s\n' "$sample_env_bot" > "$tmp/env_bot.txt"
    printf '%s\n' "$sample_env_key" > "$tmp/env_key.txt"
    printf '%s\n' "$sample_env_spaced" > "$tmp/env_spaced.txt"
    printf '%s\n' "$sample_json" > "$tmp/json.txt"
    printf '%s\n' "$sample_json_camel" > "$tmp/json_camel.txt"
    printf '%s\n' "$sample_yaml" > "$tmp/yaml.txt"
    printf '%s\n' "$sample_toml" > "$tmp/toml.txt"
    printf '%s\n' "$sample_export" > "$tmp/export.txt"
    printf '%s\n' "$sample_cjk" > "$tmp/cjk.txt"
    printf '%s\n' "$sample_bearer" > "$tmp/bearer.txt"
    printf '%s\n' "$sample_pem" > "$tmp/pem.txt"
    printf '%s\n' "$sample_openssh" > "$tmp/openssh.txt"
    printf '%s\n' "$sample_ssh2" > "$tmp/ssh2.txt"
    printf '%s\n' "$sample_pgp" > "$tmp/pgp.txt"
    printf '%s\n' "$sample_mixed_value" > "$tmp/mixed_value.txt"

    expect_hit "AWS access key ID" "$tmp/aws.txt"
    expect_hit "temporary AWS access key ID" "$tmp/aws_temp.txt"
    expect_hit "GitHub token" "$tmp/github.txt"
    expect_hit "GitHub fine-grained PAT" "$tmp/github_pat.txt"
    expect_hit "Slack bot token" "$tmp/slack.txt"
    expect_hit "Slack user token" "$tmp/slack_user.txt"
    expect_hit "Stripe live key" "$tmp/stripe_live.txt"
    expect_hit "Stripe test key" "$tmp/stripe_test.txt"
    expect_hit "provider key with a hyphenated prefix" "$tmp/provider.txt"
    expect_hit "age secret key" "$tmp/age.txt"
    expect_hit "JWT" "$tmp/jwt.txt"
    expect_hit "connection string with a credential" "$tmp/connstr.txt"
    expect_hit "prefixed uppercase key (AWS_SECRET_ACCESS_KEY)" "$tmp/upper_env.txt"
    expect_hit "unquoted passphrase value (DB_PASSWORD)" "$tmp/env_phrase.txt"
    expect_hit "sample password value (hunter2 prefix is reported)" "$tmp/env_sample.txt"
    expect_hit "prefixed uppercase key (SLACK_BOT_TOKEN)" "$tmp/env_bot.txt"
    expect_hit "uppercase key with an unquoted value (SECRET_KEY)" "$tmp/env_key.txt"
    expect_hit "quoted value with spaces (PASSWORD)" "$tmp/env_spaced.txt"
    expect_hit "JSON quoted key" "$tmp/json.txt"
    expect_hit "JSON camelCase key" "$tmp/json_camel.txt"
    expect_hit "YAML key with a colon" "$tmp/yaml.txt"
    expect_hit "TOML key with spaces and quotes" "$tmp/toml.txt"
    expect_hit "exported environment assignment" "$tmp/export.txt"
    expect_hit "Chinese key name" "$tmp/cjk.txt"
    expect_hit "Authorization: Bearer header" "$tmp/bearer.txt"
    expect_hit "PEM private key header" "$tmp/pem.txt"
    expect_hit "OpenSSH private key header" "$tmp/openssh.txt"
    expect_hit "SSH2 private key header" "$tmp/ssh2.txt"
    expect_hit "PGP private key block header" "$tmp/pgp.txt"
    expect_hit "mixed-case value with digits (not filtered as an identifier)" "$tmp/mixed_value.txt"

    # --- documented look-alikes that must stay clean --------------------------
    #
    # Each block pins one documented boundary: placeholder and template values,
    # a credential-free or documentation-host URL, prose that merely mentions a
    # key, a value that is too short, a configuration-looking line whose value
    # is a code identifier, and a value made of non-ASCII text.
    {
        printf '%s\n' 'token='"YOUR_TOKEN_HERE"
        printf '%s\n' 'password: '"<redacted>"
        printf 'api_key = %s\n' "${sample_dq}REPLACE_ME${sample_dq}"
        printf 'secret: %s\n' '...'
        printf 'password: %s\n' '${DB_PASSWORD}'
        printf '%s\n' 'prefixonly: AKIA'
        printf '%s\n' 'empty: password='
        printf '%s\n' 'short: password=abc'
        printf '%s\n' 'prose: rotate the api_key= value in the config'
        printf '%s\n' 'documentation: BEGIN PRIVATE KEY is not a header'
        printf 'chinese value: password: %s\n' '请输入你的密码'
    } > "$tmp/clean.txt"
    expect_clean "placeholder and look-alike text" "$tmp/clean.txt"

    {
        printf '%s\n' 'HTTPS_PROXY=http://proxy-user:proxy-pass@proxy.example.invalid:8080'
        printf '%s\n' 'DATABASE_URL=https://db.internal.example.invalid/docs'
    } > "$tmp/clean_urls.txt"
    expect_clean "documentation hosts" "$tmp/clean_urls.txt"

    {
        printf '%s\n' 'DEPLOY_URL=https://user@deploy.internal/repo'
        printf '%s\n' 'README_URL=https://docs.internal/guide'
    } > "$tmp/clean_no_password.txt"
    expect_clean "a URL without a password is not reported" "$tmp/clean_no_password.txt"

    {
        printf '%s\n' 'password: effectivePassword'
        printf '%s\n' '            remoteAccessPassword: remoteAccessPassword,'
        printf '%s\n' 'hasStoredPassword = RemoteAccessPasswordValue'
    } > "$tmp/clean_identifiers.txt"
    expect_clean "camelCase identifiers as values" "$tmp/clean_identifiers.txt"

    {
        printf 'TOKEN=%s\n' "${sample_dq}MySecretPassword${sample_dq}"
    } > "$tmp/quoted_identifier.txt"
    expect_hit "a quoted camelCase value (quoting is the config signal)" "$tmp/quoted_identifier.txt"

    # --- suppression ----------------------------------------------------------
    #
    # A marker with a reason suppresses exactly its own line, is counted, and is
    # still printed with the `scan-secrets: suppressed:` prefix. The old bare
    # marker, an empty reason and a too-short reason are reported as findings and
    # counted as rejected.
    sample_suppressable=$(printf 'token=%s' 'suppressed-sample-value')
    printf '%s  # %s(reason=%s)\n' "$sample_suppressable" "$SUPPRESS_MARKER" 'redaction fixture' \
        > "$tmp/suppressed.txt"
    printf '%s\n' "$sample_suppressable" > "$tmp/unsuppressed.txt"
    {
        printf '# %s(reason=%s)\n' "$SUPPRESS_MARKER" 'redaction fixture'
        printf '%s\n' "$sample_suppressable"
    } > "$tmp/marker_elsewhere.txt"
    printf '# %s(reason=%s)\n' "$SUPPRESS_MARKER" 'redaction fixture' > "$tmp/marker_only.txt"
    printf '%s  # %s\n' "$sample_suppressable" "$SUPPRESS_MARKER" > "$tmp/marker_bare.txt"
    printf '%s  # %s(reason=)\n' "$sample_suppressable" "$SUPPRESS_MARKER" > "$tmp/marker_empty.txt"
    printf '%s  # %s(reason=%s)\n' "$sample_suppressable" "$SUPPRESS_MARKER" '    ' \
        > "$tmp/marker_blank.txt"
    printf '%s  # %s(reason=%s)\n' "$sample_suppressable" "$SUPPRESS_MARKER" 'xy' \
        > "$tmp/marker_short.txt"

    before_marked=$(suppressed_count)
    expect_clean "a matched line carrying a suppression marker with a reason" "$tmp/suppressed.txt"
    after_marked=$(suppressed_count)
    if [ "$after_marked" -eq $((before_marked + 1)) ]; then
        printf 'self-test: ok: suppression counter grew by exactly 1 (%s -> %s)\n' \
            "$before_marked" "$after_marked"
    else
        printf 'self-test: FAIL: suppression counter went %s -> %s, expected %s\n' \
            "$before_marked" "$after_marked" "$((before_marked + 1))" >&2
        failures=$((failures + 1))
    fi
    expect_output_contains 'scan-secrets: suppressed: ' \
        "a suppressed line is printed with the suppressed prefix"
    expect_output_lacks 'scan-secrets: rejected ' \
        "a valid marker is not counted as rejected"

    expect_hit "the same matched line without the suppression marker" "$tmp/unsuppressed.txt"
    expect_hit "a matched line in a file whose marker sits on another line" "$tmp/marker_elsewhere.txt"
    expect_clean "a suppression marker with no credential shape" "$tmp/marker_only.txt"

    before_rejected=$(rejected_count)
    expect_hit "the old bare suppression marker" "$tmp/marker_bare.txt"
    expect_output_contains 'scan-secrets: warning: ' \
        "the bare marker prints a warning naming the line"
    expect_hit "a marker with an empty reason" "$tmp/marker_empty.txt"
    expect_hit "a marker whose reason is whitespace only" "$tmp/marker_blank.txt"
    expect_hit "a marker whose reason is too short" "$tmp/marker_short.txt"
    after_rejected=$(rejected_count)
    if [ "$after_rejected" -eq $((before_rejected + 4)) ]; then
        printf 'self-test: ok: rejected-marker counter grew by exactly 4 (%s -> %s)\n' \
            "$before_rejected" "$after_rejected"
    else
        printf 'self-test: FAIL: rejected-marker counter went %s -> %s, expected %s\n' \
            "$before_rejected" "$after_rejected" "$((before_rejected + 4))" >&2
        failures=$((failures + 1))
    fi
    # The end-of-run summary is printed by the entry point; produce the same
    # text here so the counters are also checked in their user-visible form.
    report_suppression_summary > "$SAMPLE_OUTPUT" 2>&1
    expect_output_contains 'scan-secrets: suppressed ' \
        "the summary always reports the suppressed lines"
    expect_output_contains 'scan-secrets: rejected ' "a rejected marker is summarized"

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

    # Remove the samples and the raw match records here instead of relying on
    # the EXIT trap, and prove that they are gone.
    scratch=$TMP_SCAN
    rm -rf "$tmp" "$scratch"
    TMP_SAMPLES=
    TMP_SCAN=
    if [ -e "$tmp" ] || [ -e "$scratch" ]; then
        printf 'self-test: FAIL: sample directory %s was not removed\n' "$tmp" >&2
        failures=$((failures + 1))
    else
        printf 'self-test: ok: sample directory removed\n'
    fi

    if [ "$failures" -ne 0 ]; then
        printf 'self-test: FAILED (%s failure(s))\n' "$failures" >&2
        return 1
    fi
    printf 'self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)\n'
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
            report_suppression_summary
            if [ "$INCLUDE_UNTRACKED" -eq 1 ]; then
                printf 'scan-secrets: PASS (no matches in tracked or untracked files)\n'
            else
                printf 'scan-secrets: PASS (no matches in tracked files; no untracked files)\n'
            fi
            exit 0
            ;;
        1)
            report_suppression_summary
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

report_suppression_summary
if [ "$found" -ne 0 ]; then
    printf 'scan-secrets: FAIL: matches listed above\n' >&2
    exit 1
fi
printf 'scan-secrets: PASS (no matches)\n'
exit 0
