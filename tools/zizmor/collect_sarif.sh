#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external tool output

# collect_sarif.sh — collect the zizmor SARIF into the wrangle metadata
# directory, and disambiguate "found issues" from "tool error" so
# lib/check_results.sh can fail closed on real errors.
#
# Background (issue #222):
#   The upstream zizmorcore/zizmor-action runs `docker run … | tee
#   "${output}"` and unconditionally exports the output-file path when
#   `advanced-security: true`. That means:
#     * `SARIF_SRC` is *always* non-empty in our config.
#     * The file referenced by `SARIF_SRC` exists regardless of whether
#       docker succeeded — `tee` creates it eagerly. On image-pull
#       failure, OOM, or a mid-run crash, the file is empty or holds
#       partial/garbled JSON.
#   The previous implementation only wrote the tool-error marker on the
#   "no SARIF" branch, which therefore never fired for the common error
#   modes — check_results.sh would read the empty file as zero findings
#   and fail open. See the discussion on PR #262.
#
# Disambiguation strategy:
#   On OUTCOME == "failure", trust the SARIF only when it parses AND
#   contains at least one result. zizmor exits 14 (→ outcome=failure)
#   only after writing a complete SARIF with findings, so a parseable
#   SARIF with results correlates with "real findings". Everything else
#   (file missing, empty, malformed, or zero results with outcome
#   failure) is treated as a tool error: we write the marker so the
#   downstream check_results.sh step fails closed for :fail policy and
#   logs informatively for :info policy.
#
#   A SARIF that parses but is partially truncated (e.g., docker crashed
#   mid-stream after some findings) is preserved and reported via the
#   normal count path. That may under-report relative to what a clean
#   run would have shown, but it never silently drops to zero — :fail
#   policy still blocks because the count is > 0.
#
# Inputs (env):
#   SARIF_SRC  — upstream action's output-file path (may point at a
#                missing/empty/garbage file)
#   OUTCOME    — upstream step's outcome string (success/failure/etc.)
#
# Args:
#   $1 — metadata directory (e.g.,
#        $GITHUB_WORKSPACE/.wrangle/metadata/zizmor)
#
# Side effects:
#   * Writes <metadata_dir>/output.sarif (copy of upstream's SARIF, or
#     a synthesised empty SARIF if upstream produced none/garbage).
#   * Writes <metadata_dir>/error when the upstream step failed and the
#     SARIF is not a parseable SARIF with at least one finding.
#
# Exit: 0 on success — the marker, not this script's exit code, is what
# check_results.sh consumes.

if [[ $# -ne 1 ]]; then
    printf 'Usage: collect_sarif.sh <metadata_dir>\n' >&2
    exit 1
fi

METADATA_DIR="$1"
mkdir -p "$METADATA_DIR"

SARIF_DST="${METADATA_DIR}/output.sarif"
ERROR_MARKER="${METADATA_DIR}/error"

# Default OUTCOME so missing env doesn't trigger set -u.
: "${OUTCOME:=}"
SARIF_SRC="${SARIF_SRC:-}"

# Inspect the upstream SARIF: does it parse, and does it report results?
# `jq -e` exits non-zero on null/false/parse-failure, so a missing or
# malformed file falls through to count=-1 and trips the error path.
src_count=-1
if [[ -n "$SARIF_SRC" ]] && [[ -f "$SARIF_SRC" ]] && [[ -s "$SARIF_SRC" ]]; then
    if parsed_count="$(jq '[.runs[]?.results[]?] | length' "$SARIF_SRC" 2>/dev/null)"; then
        # Numeric sanity check — defend against jq returning something
        # unexpected on weird inputs.
        if [[ "$parsed_count" =~ ^[0-9]+$ ]]; then
            src_count="$parsed_count"
        fi
    fi
fi

if [[ "$OUTCOME" == "failure" ]] && [[ "$src_count" -le 0 ]]; then
    # Tool error: upstream failed and the SARIF either does not exist,
    # is empty, fails to parse, or contains zero results. None of these
    # correspond to "zizmor ran cleanly and found nothing" (that would
    # be outcome=success). Drop the marker so check_results.sh fails
    # closed for :fail and logs informatively for :info.
    #
    # `[[ -le ]]` (rather than `(( ))`) is deliberate: arithmetic
    # contexts exit non-zero when the expression evaluates to 0, which
    # under `set -e` could short-circuit before the marker write if
    # a future edit broke the && chain. `[[ ]]` always returns the
    # comparison result without side effects.
    printf 'upstream zizmor-action exited non-zero with no usable SARIF output (outcome=%s)\n' \
        "$OUTCOME" > "$ERROR_MARKER"
fi

if [[ "$src_count" -ge 0 ]]; then
    # SARIF parses — copy as-is. Note that for OUTCOME=failure with
    # src_count == 0 we have already written the marker above, so this
    # copy is purely so the step-summary collector and any Code Scanning
    # upload still see a file. For OUTCOME=failure with src_count > 0
    # (real findings), no marker exists and the count flows through
    # check_results.sh as findings, preserving :info-policy semantics.
    cp "$SARIF_SRC" "$SARIF_DST"
else
    # No usable upstream SARIF — synthesise an empty one so downstream
    # consumers (summary collector, Code Scanning upload) have a file.
    # The marker, if appropriate, was written above.
    jq -n '{
        "version": "2.1.0",
        "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
        "runs": [{"tool": {"driver": {"name": "zizmor"}}, "results": []}]
    }' > "$SARIF_DST"
fi

# Explicit exit 0: this script's role is to drop the marker and a SARIF
# file for the downstream gate (check_results.sh) to consume. Whether
# the upstream tool errored or found issues is communicated via those
# artifacts, not our exit code, so we always succeed.
exit 0
