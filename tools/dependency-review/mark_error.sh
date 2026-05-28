#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external tool output

# mark_error.sh — write the dependency-review tool-error marker.
#
# Hidden upstream contract: dependency-review-action populates the
# vulnerable-changes output on findings exit but leaves it empty/`[]`
# on genuine error (API down, Dependency Graph disabled). So
# "outcome=failure AND vulnerable-changes non-empty" means findings;
# everything else under outcome=failure is a tool error that would
# otherwise look like "no vulnerable changes" to check_results.sh.
#
# Inputs (env):
#   METADATA_DIR        — destination directory
#   OUTCOME             — upstream step's outcome string (for context)
#   VULNERABLE_CHANGES  — upstream step's vulnerable-changes output

: "${METADATA_DIR:?METADATA_DIR is required}"
: "${OUTCOME:=failure}"

# Single positive check via jq so we don't depend on serialisation form
# (`[]` vs `[ ]` vs pretty-printed vs `null`) staying byte-stable.
# Everything that isn't a non-empty array — empty, null, parse failure,
# wrong type, missing env — falls through to the marker.
if ! printf '%s' "${VULNERABLE_CHANGES:-}" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    mkdir -p "$METADATA_DIR"
    printf 'upstream dependency-review-action exited non-zero with no vulnerable-changes (outcome=%s)\n' \
        "$OUTCOME" > "$METADATA_DIR/error"
fi
