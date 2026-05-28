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
# Exit: 0 on success; non-zero on missing required env or an unwritable
# marker path (set -euo pipefail propagates failures from the redirect
# and the `: "${METADATA_DIR:?...}"` guard).

: "${METADATA_DIR:?METADATA_DIR is required}"
: "${OUTCOME:=failure}"

# Empty-array / unparseable / null detection via jq, so we don't depend
# on the upstream serialisation (`[]` vs `[ ]` vs pretty-printed vs
# `null`) staying byte-stable. A single positive check ("is this a
# non-empty array?") is true only for real findings; everything else
# (empty array, null, parse failure, wrong type, missing env) falls
# through to the marker.
should_mark=0
if ! printf '%s' "${VULNERABLE_CHANGES:-}" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    should_mark=1
fi

if [[ "$should_mark" -eq 1 ]]; then
    mkdir -p "$METADATA_DIR"
    printf 'upstream dependency-review-action exited non-zero with no vulnerable-changes (outcome=%s)\n' \
        "$OUTCOME" > "$METADATA_DIR/error"
fi
