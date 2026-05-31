#!/bin/bash
set -euo pipefail
set -f

# Writes the GitHub Actions step summary for the Python build composite.
# Renders a markdown table with package / version, plus a list of every
# file in <input_path>/dist/.
#
# Usage: generate_summary.sh <input_path> <version>
#
#   input_path: project directory (the "Package" label and dist/ root).
#   version:    the package version (or "unknown").

if [[ $# -ne 2 ]]; then
    printf 'Usage: generate_summary.sh <input_path> <version>\n' >&2
    exit 1
fi

# input_path is the action's inputs.path, already constrained by
# validate_inputs.sh (lib/validate_path.sh) — the composite's first step,
# which runs before this one; no untrusted value reaches the dist/* glob below.
INPUT_PATH="$1"
VERSION="$2"

if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf 'Note: GITHUB_STEP_SUMMARY not set; printing to stdout instead.\n'
    OUT=/dev/stdout
else
    OUT="$GITHUB_STEP_SUMMARY"
fi

{
    printf '## Python Build Results\n\n'
    printf '| | |\n|---|---|\n'
    printf '| **Package** | %s |\n' "$INPUT_PATH"
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
