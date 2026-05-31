#!/bin/bash
set -euo pipefail
set -f

# Run shellcheck over every .sh / .bats file under <scan-path>.
#
# Its diagnostics echo excerpts of the source lines they flag, and the
# source files under scan-path are caller-controlled. A `.sh` file with a
# line starting `::add-mask::` or `::set-output::` could otherwise reach
# the step log via that output. The invocation runs under
# stop_commands_guard.sh, which neutralizes workflow commands on stdout
# and re-enables command processing before the final "scripts passed"
# line — see #225 / docs/SLSA_L3_AUDIT.md Finding 3.
#
# Usage: run_shellcheck.sh <scan-path>

if [[ $# -ne 1 ]]; then
    printf 'Usage: run_shellcheck.sh <scan-path>\n' >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../../../lib/stop_commands_guard.sh"
SCAN_PATH="$1"

printf '=== shellcheck ===\n'

# Validate scan-path: must be a relative path with only safe characters.
# Reject absolute paths and path traversal.
if [[ "$SCAN_PATH" == /* ]]; then
    printf 'shellcheck: absolute paths not allowed in scan-path: %s\n' "$SCAN_PATH" >&2
    exit 1
fi
if [[ "$SCAN_PATH" == *..* ]]; then
    printf 'shellcheck: path traversal not allowed in scan-path: %s\n' "$SCAN_PATH" >&2
    exit 1
fi
if [[ ! "$SCAN_PATH" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
    printf 'shellcheck: invalid characters in scan-path: %s\n' "$SCAN_PATH" >&2
    exit 1
fi
if [[ ! -d "$SCAN_PATH" ]]; then
    printf 'shellcheck: scan-path does not exist: %s\n' "$SCAN_PATH" >&2
    exit 1
fi

# find -print0 + xargs -0 for safe filename handling. shellcheck also
# supports .bats files (bash syntax). Each xargs batch is one guarded
# invocation; the guard preserves shellcheck's exit status so findings
# still fail the step.
find "$SCAN_PATH" \( -name '*.sh' -o -name '*.bats' \) \
    -not -path '*/.git/*' \
    -not -path '*/node_modules/*' \
    -print0 | xargs -0 -r "$GUARD" run shellcheck
printf 'shellcheck: all scripts under %s passed\n' "$SCAN_PATH"
