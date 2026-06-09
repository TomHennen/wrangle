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
VALIDATE_PATH="$SCRIPT_DIR/../../../lib/validate_path.sh"
SCAN_PATH="$1"

printf '=== shellcheck ===\n'

# Enforce the shared path allowlist (relative, no traversal, safe charset)
# via lib/validate_path.sh; it exits non-zero and set -e aborts here. The
# existence check is shellcheck-specific — validate_path.sh is pure string
# validation, and a missing scan-path is caller error, not a no-op.
"$VALIDATE_PATH" "$SCAN_PATH"
if [[ ! -d "$SCAN_PATH" ]]; then
    printf 'shellcheck: scan-path does not exist: %s\n' "$SCAN_PATH" >&2
    exit 1
fi

# find -print0 + xargs -0 for safe filename handling. Each xargs batch is
# one guarded invocation; the guard preserves shellcheck's exit status so
# findings still fail the step. -x --source-path=SCRIPTDIR follows
# `source`d libs relative to each script's own directory, so findings in
# sourced helpers surface instead of being masked by SC1091 "not following".
find "$SCAN_PATH" -name '*.sh' \
    -not -path '*/.git/*' \
    -not -path '*/node_modules/*' \
    -print0 | xargs -0 -r "$GUARD" run shellcheck -x --source-path=SCRIPTDIR

# .bats files (bash syntax) are linted at warning+ only: shellcheck's
# info/style classes misfire on core bats idioms — every @test runs in its
# own subshell (SC2030/SC2031) and fixture strings carry literal `$`
# (SC2016) — which would bury the real findings for any bats suite.
find "$SCAN_PATH" -name '*.bats' \
    -not -path '*/.git/*' \
    -not -path '*/node_modules/*' \
    -print0 | xargs -0 -r "$GUARD" run shellcheck -x --source-path=SCRIPTDIR --severity=warning
printf 'shellcheck: all scripts under %s passed\n' "$SCAN_PATH"
