#!/bin/bash
set -euo pipefail
set -f

# tools/check_showcase_run_green.sh — release gate: the latest completed
# tracking-tag run of the wrangle-test showcase must be green. Tracking tags
# (vYYYYMMDD-<wrangle-sha7>, see docs/RELEASING.md) are the automatic
# current-state heartbeat pushed on every main commit; curated vX.Y.Z tags are
# excluded — they're cut manually and don't track main.
#
# Read-only, by design: the Release Gate's token cannot act on another repo,
# and preflight must stay read-only. A red run blocks with its URL; the remedy
# is a human re-running it in wrangle-test — preflight passes once a newer run
# is green. This also means a transient flake (#354) is never re-run from here.
#
# Exit: 0 latest completed tracking-tag run is green, 1 it's red, 2 could not
# determine (gh/jq missing, the API unreachable, or no completed tracking-tag
# run exists yet).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/gh_run_status.sh
source "$SCRIPT_DIR/../lib/gh_run_status.sh"
# The tracking-tag shape this gate looks for is produced by
# test/integration/push_showcase_tag.sh; both source it from here.
# shellcheck source=../lib/tracking_tag.sh
source "$SCRIPT_DIR/../lib/tracking_tag.sh"

WRANGLE_SHOWCASE_REPO="${WRANGLE_SHOWCASE_REPO:-TomHennen/wrangle-test}"
WRANGLE_SHOWCASE_WORKFLOW="${WRANGLE_SHOWCASE_WORKFLOW:-showcase.yml}"

check_showcase_run_green() {
    local result conclusion url

    if ! result="$(wrangle_latest_completed_run "$WRANGLE_SHOWCASE_REPO" "$WRANGLE_SHOWCASE_WORKFLOW" "$WRANGLE_TRACKING_TAG_RE")"; then
        printf 'check_showcase_run_green: could not determine the wrangle-test showcase status\n' >&2
        return 2
    fi
    conclusion="${result%%$'\t'*}"
    url="${result#*$'\t'}"

    if [[ "$conclusion" != "success" ]]; then
        printf 'check_showcase_run_green: latest completed tracking-tag showcase run is %s: %s\n' "$conclusion" "$url" >&2
        printf '  remediation: re-run it; preflight passes once a newer run is green\n' >&2
        return 1
    fi
    printf 'check_showcase_run_green: latest completed tracking-tag showcase run is green: %s\n' "$url"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -gt 0 ]]; then
        printf 'Usage: %s\n' "${0##*/}" >&2
        exit 2
    fi
    check_showcase_run_green
fi
