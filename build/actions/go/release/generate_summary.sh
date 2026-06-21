#!/bin/bash
# Writes the GitHub Actions step summary for the Go release composite.
# Renders a markdown table with project / version, plus a list of
# every file in <dist_dir>/.
#
# Usage: build/actions/go/release/generate_summary.sh <input_path> <version>
#
#   input_path: project directory (used as the "Project" label and
#               to locate dist/).
#   version:    the release version (tag or "snapshot").

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <input_path> <version>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
VERSION="$2"

if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf 'Note: GITHUB_STEP_SUMMARY not set; printing to stdout instead.\n'
    OUT=/dev/stdout
else
    OUT="$GITHUB_STEP_SUMMARY"
fi

{
    printf '## Go Release Results\n\n'
    printf '| | |\n|---|---|\n'
    printf '| **Project** | %s |\n' "$INPUT_PATH"
    printf '| **Version** | %s |\n' "$VERSION"
    printf '| **Artifacts** | |\n'
    # Expand dist/* inside a subshell so globbing is restored on every
    # exit path — a bare `set +f` here would leak glob-enabled state to
    # the rest of the script if the loop aborted under set -e.
    (
        set +f
        for f in "$INPUT_PATH"/dist/*; do
            if [[ -f "$f" ]]; then
                # shellcheck disable=SC2016 # backticks here are human-readable markdown, not command substitution
                printf '| | `%s` |\n' "$(basename "$f")"
            fi
        done
    )
} >> "$OUT"
