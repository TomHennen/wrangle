#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external tool output

# mark_error.sh — write the dependency-review tool-error marker.
#
# Hidden upstream contract: dependency-review-action populates
# vulnerable-changes on findings but leaves it empty/`[]` on genuine
# error (API down, Dependency Graph disabled). VULNERABLE_CHANGES is
# attacker-influenced JSON, so the only check that touches it is a jq
# parse — never a shell expansion.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/write_tool_error_marker.sh
source "$SCRIPT_DIR/../../lib/write_tool_error_marker.sh"

: "${METADATA_DIR:?METADATA_DIR is required}"
: "${OUTCOME:=failure}"

# Single positive check via jq so serialisation form (`[]` vs `[ ]` vs
# pretty-printed vs `null`) doesn't matter. Everything that isn't a
# non-empty array — empty, null, parse failure, wrong type, missing
# env — falls through to the marker.
if ! printf '%s' "${VULNERABLE_CHANGES:-}" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    wrangle_write_tool_error_marker "$METADATA_DIR" \
        "upstream dependency-review-action exited non-zero with no vulnerable-changes (outcome=${OUTCOME})"
fi
