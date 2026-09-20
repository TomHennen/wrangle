#!/bin/bash
set -euo pipefail
set -f

# lib/gh_run_status.sh — shared helper for release-preflight gates that judge a
# workflow by its own run history (an unattended showcase or scheduled check
# that nobody watches) rather than by re-deriving the result locally.
#
# Provides:
#   wrangle_latest_completed_run — the newest completed run of a workflow whose
#                                  head ref matches a caller-given regex

_GH_RUN_STATUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retry.sh
source "$_GH_RUN_STATUS_DIR/retry.sh"

# wrangle_latest_completed_run <repo> <workflow> <ref_regex> — print
# "<conclusion>\t<url>" for the newest completed run of <workflow> in <repo>
# whose head branch/tag matches <ref_regex> (a jq/Oniguruma regex). Read-only:
# this never re-runs a workflow, so a flaky run (#354) is never silently
# retried into a pass here — only a genuinely newer run does that. The `gh run
# list` call is retried once via wrangle_retry_once to absorb a transient API
# blip; the surviving attempt's output is what gets evaluated.
# Returns 2 if gh/jq are missing, the API call fails on both attempts, or no
# completed run matches.
wrangle_latest_completed_run() {
    local repo="$1" workflow="$2" ref_regex="$3"
    local json result rc=0

    if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        printf 'gh_run_status: gh and jq are required\n' >&2
        return 2
    fi

    json="$(mktemp)"
    wrangle_retry_once "$json" gh run list \
        --repo "$repo" --workflow "$workflow" --status completed --limit 50 \
        --json conclusion,url,headBranch,createdAt || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        rm -f "$json"
        printf 'gh_run_status: could not list runs for %s workflow %s\n' "$repo" "$workflow" >&2
        return 2
    fi

    result="$(jq -r --arg re "$ref_regex" '
        map(select(.headBranch | test($re)))
        | sort_by(.createdAt) | last
        | if . == null then empty else [.conclusion, .url] | @tsv end
    ' "$json")" || { rm -f "$json"; printf 'gh_run_status: malformed run list for %s workflow %s\n' "$repo" "$workflow" >&2; return 2; }
    rm -f "$json"

    if [[ -z "$result" ]]; then
        printf 'gh_run_status: no completed run of %s in %s matches ref %s\n' "$workflow" "$repo" "$ref_regex" >&2
        return 2
    fi
    printf '%s\n' "$result"
}
