#!/bin/bash
set -euo pipefail
set -f

# tools/wrangle-doc-lint/lint.sh — validate `→ enforced by:` pointers in
# spec docs (see lint.py for the pointer grammar and the WDL rules).
#
# An invariant in docs/SPEC.md cites the test or lint rule that enforces
# it; this linter fails the build when a cited file, bats test, or rule ID
# no longer exists — so a rename or deletion that silently strands a spec
# claim is caught the same way a broken build is.
#
# lint.py is python3 stdlib only — no venv, no requirements.txt.
#
# Usage:
#   lint.sh                       lint docs/SPEC.md against the repo root
#   lint.sh [--root DIR] <doc>..  lint specific docs (refs resolve under DIR)
#
# Exit: 0 clean, 1 violations found, 2 tool error (fail closed).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    printf 'wrangle-doc-lint: python3 not found on PATH.\n' >&2
    exit 2
fi

if [[ "${1:-}" == "--root" && $# -ge 2 ]]; then
    repo_root="$2"
    shift 2
else
    repo_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || \
        repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

declare -a targets=()
if [[ $# -gt 0 ]]; then
    targets=("$@")
else
    targets=("$repo_root/docs/SPEC.md")
fi

exec python3 "$SCRIPT_DIR/lint.py" --root "$repo_root" "${targets[@]}"
