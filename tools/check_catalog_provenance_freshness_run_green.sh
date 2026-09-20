#!/bin/bash
set -euo pipefail
set -f

# tools/check_catalog_provenance_freshness_run_green.sh — release gate: the
# latest completed run of catalog_provenance_freshness.yml on main must be
# green. That workflow only runs on schedule/workflow_dispatch and nobody
# watches the Actions tab (#839), so a red run can sit unnoticed until a
# release is being cut.
#
# Read-only: preflight never re-runs the workflow. A red run blocks with its
# URL; the remedy is re-publishing and bumping the stale image
# (tools/check_catalog_provenance_freshness.sh prints which one) and
# re-running — preflight passes once a newer run is green.
#
# Exit: 0 latest completed main run is green, 1 it's red, 2 could not determine
# (gh/jq missing, the API unreachable, or no completed run on main exists yet).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/gh_run_status.sh
source "$SCRIPT_DIR/../lib/gh_run_status.sh"

WRANGLE_OWN_REPO="${WRANGLE_OWN_REPO:-TomHennen/wrangle}"
WRANGLE_CATALOG_PROVENANCE_FRESHNESS_WORKFLOW="${WRANGLE_CATALOG_PROVENANCE_FRESHNESS_WORKFLOW:-catalog_provenance_freshness.yml}"
DEFAULT_BRANCH_RE='^main$'

check_catalog_provenance_freshness_run_green() {
    local result conclusion url

    if ! result="$(wrangle_latest_completed_run "$WRANGLE_OWN_REPO" "$WRANGLE_CATALOG_PROVENANCE_FRESHNESS_WORKFLOW" "$DEFAULT_BRANCH_RE")"; then
        printf 'check_catalog_provenance_freshness_run_green: could not determine the scheduled catalog provenance freshness run status\n' >&2
        return 2
    fi
    conclusion="${result%%$'\t'*}"
    url="${result#*$'\t'}"

    if [[ "$conclusion" != "success" ]]; then
        printf 'check_catalog_provenance_freshness_run_green: latest completed main run of %s is %s: %s\n' "$WRANGLE_CATALOG_PROVENANCE_FRESHNESS_WORKFLOW" "$conclusion" "$url" >&2
        printf '  remediation: re-run it; preflight passes once a newer run is green\n' >&2
        return 1
    fi
    printf 'check_catalog_provenance_freshness_run_green: latest completed main run of %s is green: %s\n' "$WRANGLE_CATALOG_PROVENANCE_FRESHNESS_WORKFLOW" "$url"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -gt 0 ]]; then
        printf 'Usage: %s\n' "${0##*/}" >&2
        exit 2
    fi
    check_catalog_provenance_freshness_run_green
fi
