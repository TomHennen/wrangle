#!/bin/bash
# Validates inputs to the Go checks composite: shared path checks via
# lib/validate_path.sh, plus go.mod presence in the project directory.
#
# Does NOT require `.goreleaser.yml` — the checks composite runs
# quality gates that are useful even on projects that haven't yet
# wired up goreleaser. The release composite's validate_inputs.sh
# enforces .goreleaser.yml presence at that side of the pipeline.
#
# Usage: build/actions/go/checks/validate_inputs.sh <path>

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <path>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/../../../../lib/validate_path.sh" "$INPUT_PATH"

if [[ ! -f "$INPUT_PATH/go.mod" ]]; then
    printf 'Error: no go.mod found in %s\n' "$INPUT_PATH" >&2
    # shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
    printf 'Hint: run `go mod init <module>` in the project directory.\n' >&2
    exit 1
fi
