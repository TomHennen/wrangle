#!/bin/bash
set -euo pipefail

# collect_outputs.sh — produce wrangle metadata for the dependency-review tool.
#
# Reads the dependency-review-action `vulnerable-changes` JSON from the
# VULNERABLE_CHANGES environment variable (unset/empty = no findings),
# converts it to SARIF via vulnerable_changes_to_sarif.sh, and writes both
# output.sarif and a human-readable output.md into <metadata_dir>.
#
# The SARIF write is atomic (temp file + mv) so a converter failure never
# leaves a partial output.sarif behind for the downstream Check results
# step to misread.
#
# Usage: collect_outputs.sh <metadata_dir>
# Exit:  0 on success, 1 on usage error, 2 on SARIF conversion failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ne 1 ]]; then
    printf 'Usage: collect_outputs.sh <metadata_dir>\n' >&2
    exit 1
fi

METADATA_DIR="$1"
mkdir -p "$METADATA_DIR"

SARIF_DST="${METADATA_DIR}/output.sarif"
MD_DST="${METADATA_DIR}/output.md"

JSON_TMP="$(mktemp "${TMPDIR:-/tmp}/wrangle-depreview-XXXXXX.json")"
SARIF_TMP="$(mktemp "${TMPDIR:-/tmp}/wrangle-depreview-XXXXXX.sarif")"
trap 'rm -f "$JSON_TMP" "$SARIF_TMP"' EXIT

# dep-review's vulnerable-changes output; empty when the action did not
# run or found nothing. The converter normalises empty input to "[]".
printf '%s' "${VULNERABLE_CHANGES:-[]}" > "$JSON_TMP"

# Atomic SARIF write: build in a temp file, mv on success. A non-zero
# exit from the converter (malformed JSON, jq failure) leaves SARIF_DST
# absent, which the Check results step treats as a tool failure rather
# than reading partial JSON.
conv_exit=0
"$SCRIPT_DIR/vulnerable_changes_to_sarif.sh" "$JSON_TMP" > "$SARIF_TMP" || conv_exit=$?
if [[ "$conv_exit" -ne 0 ]]; then
    printf 'dependency-review: SARIF conversion failed (exit %d)\n' "$conv_exit" >&2
    exit 2
fi
mv "$SARIF_TMP" "$SARIF_DST"

# Human-readable markdown for the step summary details section.
"$SCRIPT_DIR/../../lib/sarif_to_md.sh" "$SARIF_DST" > "$MD_DST"
