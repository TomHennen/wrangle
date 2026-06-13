#!/bin/bash
set -euo pipefail
set -f  # disable globbing — adapter walks adopter-controlled paths

# wrangle-lint adapter for wrangle.
# Audits adopter configuration for footguns that silently defeat wrangle's
# protections (v1: Dependabot config correctness). Distinct from the security
# scanners — it checks whether the surrounding config is wired up, not the code.
#
# Usage: adapter.sh <src_dir> <output_dir>
# Exit: 0 = no findings, 1 = findings found, 2 = tool error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_PY="${SCRIPT_DIR}/check.py"

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

SARIF_FILE="${OUTPUT_DIR}/output.sarif"

# Resolve a python3 that can import yaml: the managed venv the test image and
# install.sh build, else a system python3 with PyYAML (local dev). The image's
# base python has no yaml, so the fallback fails closed there rather than
# masking a broken venv.
VENV_PYTHON="/opt/wrangle-lint/bin/python3"
if [[ -x "$VENV_PYTHON" ]]; then
    PYTHON="$VENV_PYTHON"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    PYTHON="python3"
else
    printf 'wrangle/wrangle-lint: no python3 with PyYAML found.\n' >&2
    printf 'wrangle/wrangle-lint: install tools/wrangle-lint/requirements.txt into a venv (see test/Dockerfile).\n' >&2
    exit 2
fi

# check.py writes the SARIF directly; a non-zero exit is a tool error
# (e.g. malformed dependabot.yml) and must fail the adapter closed.
check_exit=0
"$PYTHON" "$CHECK_PY" "$SRC_DIR" "$SARIF_FILE" || check_exit=$?
if [[ "$check_exit" -ne 0 ]]; then
    printf 'wrangle/wrangle-lint: check failed (exit %d)\n' "$check_exit" >&2
    exit 2
fi

if ! jq empty "$SARIF_FILE" 2>/dev/null; then
    printf 'wrangle/wrangle-lint: produced invalid JSON in SARIF output\n' >&2
    exit 2
fi

if ! num_findings="$(jq '[.runs[].results[]] | length' "$SARIF_FILE" 2>/dev/null)"; then
    printf 'wrangle/wrangle-lint: failed to parse SARIF results\n' >&2
    exit 2
fi
if [[ "$num_findings" -gt 0 ]]; then
    exit 1
fi

exit 0
