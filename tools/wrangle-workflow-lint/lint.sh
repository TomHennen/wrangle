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
# PyYAML is hash-pinned in tools/wrangle-workflow-lint/requirements.txt and
# installed into an isolated venv (Dependabot-covered, like zizmor /
# ast-grep — see DEP_MGMT.md). Being a library rather than a CLI it has no
# PATH entrypoint, so this wrapper runs lint.py under the venv's python.
#
# Usage:
#   lint.sh                walk the repo (workflows + composite action.yml)
#   lint.sh <file> [...]   lint specific YAML files only
#
# Exit: 0 clean, 1 violations found, 2 tool error (fail closed).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT_PY="${SCRIPT_DIR}/lint.py"

# Resolve the interpreter that can import yaml. Prefer the managed venv the
# test image builds; fall back to a system python3 that already has PyYAML
# (a local dev convenience). In the image the base python has no yaml, so
# this fallback fails closed there rather than masking a broken venv.
VENV_PYTHON="/opt/wrangle-workflow-lint/bin/python3"
if [[ -x "$VENV_PYTHON" ]]; then
    PYTHON="$VENV_PYTHON"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    PYTHON="python3"
else
    printf 'wrangle-workflow-lint: no python3 with PyYAML found.\n' >&2
    printf 'wrangle-workflow-lint: install the pinned version in tools/wrangle-workflow-lint/requirements.txt into a venv (see test/Dockerfile).\n' >&2
    exit 2
fi

# Collect target files. Explicit args are used verbatim; otherwise walk the
# repo for workflow files and every composite action.yml, skipping this
# linter's own fixtures (intentionally-bad YAML that must not fail the repo
# walk or the zizmor scan).
#
# Targets are trusted developer input — git-discovered repo files or a dev's
# explicit file list run from `make test` — not attacker-controlled
# workflow_call inputs, so no path allowlisting is applied here (unlike the
# build actions, whose inputs.* flow through lib/validate_path.sh).
declare -a targets=()
if [[ $# -gt 0 ]]; then
    targets=("$@")
else
    repo_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || \
        repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
    while IFS= read -r -d '' f; do
        targets+=("$f")
    done < <(find "$repo_root" \
        \( -path '*/.git/*' -o -path '*/.beads/*' -o -path '*/.claude/*' \
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

exec "$PYTHON" "$LINT_PY" "${targets[@]}"
