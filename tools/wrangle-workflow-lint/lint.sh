#!/bin/bash
set -euo pipefail
set -f

# tools/wrangle-workflow-lint/lint.sh — Wrangle workflow-style linter.
#
# Thin wrapper around lint.py (python3 + PyYAML) that enforces the
# CLAUDE.md GitHub Actions conventions operating on YAML *structure*
# rather than shell AST:
#
#   WWL001  a run: block is at most 10 physical lines
#   WWL002  no ${{ inputs.* }} / ${{ github.event.* }} inside a run: body
#   WWL003  unjustified continue-on-error on a verification-class step
#
# The shell-AST conventions (curl|sh, `set +f` outside a subshell) live in
# the sibling wrangle-shell-lint as WSL006 / WSL007.
#
# python3 + PyYAML are provided by the test image's apt packages (python3,
# python3-yaml) — the same trust model as the python3 interpreter itself,
# kept current by the base-image rebuild. No separate hash-pinned venv: a
# pure-Python parser in the base distro is not a wrapped third-party tool
# like zizmor / ast-grep (see DEP_MGMT.md footprint rule).
#
# Usage:
#   lint.sh                walk the repo (workflows + composite action.yml)
#   lint.sh <file> [...]   lint specific YAML files only
#
# Exit: 0 clean, 1 violations found, 2 tool error (fail closed).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT_PY="${SCRIPT_DIR}/lint.py"

if ! command -v python3 >/dev/null 2>&1; then
    printf 'wrangle-workflow-lint: python3 not found on PATH.\n' >&2
    exit 2
fi

# Collect target files. Explicit args are used verbatim; otherwise walk the
# repo for workflow files and every composite action.yml, skipping this
# linter's own fixtures (intentionally-bad YAML that must not fail the repo
# walk or the zizmor scan).
declare -a targets=()
if [[ $# -gt 0 ]]; then
    targets=("$@")
else
    repo_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || \
        repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
    while IFS= read -r -d '' f; do
        targets+=("$f")
    done < <(find "$repo_root" \
        \( -path '*/.git/*' -o -path '*/.beads/*' \
           -o -path '*/wrangle-workflow-lint/fixtures/*' \) -prune -o \
        -type f \( \
            -path '*/.github/workflows/*.yml' -o \
            -path '*/.github/workflows/*.yaml' -o \
            -name 'action.yml' -o \
            -name 'action.yaml' \
        \) -print0 | sort -z)
fi

if [[ ${#targets[@]} -eq 0 ]]; then
    exit 0
fi

exec python3 "$LINT_PY" "${targets[@]}"
