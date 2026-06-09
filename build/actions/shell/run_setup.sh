#!/bin/bash
set -euo pipefail
set -f

# Run the adopter's <setup-script> to install test dependencies before the
# shell build's checks. Empty path is a no-op (the default), so the input is
# backward-compatible for adopters that need no setup.
#
# The script is arbitrary adopter bash and its dependencies print
# tool-controlled output, a direct workflow-command-injection path: a
# `printf '::add-mask::SECRET'` from an install hook would hijack the build
# job. It runs under stop_commands_guard.sh — see docs/SLSA_L3_AUDIT.md
# Finding 3.
#
# Usage: run_setup.sh <setup-script>
#   setup-script: workspace-relative path to a bash script, or "" to skip.

if [[ $# -ne 1 ]]; then
    printf 'Usage: run_setup.sh <setup-script>\n' >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../../../lib/stop_commands_guard.sh"
VALIDATE_PATH="$SCRIPT_DIR/../../../lib/validate_path.sh"
SETUP_SCRIPT="$1"

printf '=== setup ===\n'

if [[ -z "$SETUP_SCRIPT" ]]; then
    printf 'setup: no setup-script provided, skipping\n'
    exit 0
fi

# Enforce the shared path allowlist (relative, no traversal, safe charset)
# via lib/validate_path.sh; it exits non-zero and set -e aborts here. The
# file check is setup-specific — a missing or non-file path is caller error.
"$VALIDATE_PATH" "$SETUP_SCRIPT"
if [[ ! -f "$SETUP_SCRIPT" ]]; then
    printf 'setup: setup-script is not a file: %s\n' "$SETUP_SCRIPT" >&2
    exit 1
fi

# Run via `bash` rather than executing directly so the script need not be
# marked executable in the adopter's repo.
"$GUARD" run bash "$SETUP_SCRIPT"
printf 'setup: %s completed\n' "$SETUP_SCRIPT"
