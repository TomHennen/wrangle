#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external tool output

# mark_error.sh — write the dependency-review tool-error marker.
#
# Called from action.yml's "Mark dependency-review tool error" step when
# the upstream action's outcome is 'failure'. The upstream step
# populates the `vulnerable-changes` output when it exits non-zero on
# findings, and leaves it empty/`[]` when it exits non-zero on a genuine
# error (API down, Dependency Graph disabled, network failure).
#
# A non-empty array means findings — those flow through SARIF and are
# caught by lib/check_results.sh. An empty array (or unset variable) is
# the fail-open case from issue #222: an empty SARIF would be
# indistinguishable from "no vulnerable changes", so we write the marker
# so check_results.sh fails closed.
#
# Inputs (env):
#   METADATA_DIR        — destination directory (e.g.,
#                         $GITHUB_WORKSPACE/.wrangle/metadata/dependency-review)
#   OUTCOME             — the upstream step's outcome string (for context)
#   VULNERABLE_CHANGES  — the upstream step's vulnerable-changes output
#
# Exit: 0 unconditionally — failure to write the marker is non-fatal here
# because the surrounding step is purely a fail-closed hint.

: "${METADATA_DIR:?METADATA_DIR is required}"
: "${OUTCOME:=failure}"

if [[ -z "${VULNERABLE_CHANGES:-}" ]] || [[ "${VULNERABLE_CHANGES}" == "[]" ]]; then
    mkdir -p "$METADATA_DIR"
    printf 'upstream dependency-review-action exited non-zero with no vulnerable-changes (outcome=%s)\n' \
        "$OUTCOME" > "$METADATA_DIR/error"
fi
