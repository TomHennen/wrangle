#!/bin/bash
set -euo pipefail
set -f  # disable globbing — adapter walks adopter-controlled paths

# wrangle-lint adapter for wrangle.
# Audits adopter configuration for footguns that silently defeat wrangle's
# protections (v1: Dependabot config correctness) — distinct from the security
# scanners, which check code/workflows rather than whether config is wired up.
#
# The wrangle-lint binary is a first-party Go tool (a tool directive in
# tools/go.mod), on PATH inside this tool's image.
#
# Usage: adapter.sh <src_dir> <output_dir>
# Exit: 0 = no findings, 1 = findings found, 2 = tool error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/sarif_adapter_exit.sh
source "$SCRIPT_DIR/../../lib/sarif_adapter_exit.sh" || exit 2

if [[ $# -ne 2 ]]; then
    printf 'Usage: adapter.sh <src_dir> <output_dir>\n' >&2
    exit 2
fi

SRC_DIR="$1"
OUTPUT_DIR="$2"

if [[ ! -d "$SRC_DIR" ]]; then
    printf 'wrangle/wrangle-lint: source directory does not exist: %s\n' "$SRC_DIR" >&2
    exit 2
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    printf 'wrangle/wrangle-lint: output directory does not exist: %s\n' "$OUTPUT_DIR" >&2
    exit 2
fi

if ! command -v wrangle-lint >/dev/null 2>&1; then
    printf 'wrangle/wrangle-lint: wrangle-lint binary not on PATH (built from tools/go.mod)\n' >&2
    exit 2
fi

SARIF_FILE="${OUTPUT_DIR}/output.sarif"

# A non-zero exit is a tool error (e.g. malformed dependabot.yml); the binary
# writes the SARIF and the findings/no-findings split is derived below.
lint_exit=0
wrangle-lint "$SRC_DIR" "$SARIF_FILE" || lint_exit=$?
if [[ "$lint_exit" -ne 0 ]]; then
    printf 'wrangle/wrangle-lint: check failed (exit %d)\n' "$lint_exit" >&2
    exit 2
fi

wrangle_sarif_adapter_exit 'wrangle/wrangle-lint' "$SARIF_FILE"
