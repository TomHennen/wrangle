#!/bin/bash
# Runs the project's pytest suite for the python build action.
#
# Test discovery follows pytest's defaults (https://docs.pytest.org/en/stable/explanation/goodpractices.html):
# wrangle considers tests "present" if there is a top-level `tests/` or
# `test/` directory, or a `[tool.pytest.ini_options]` section in
# pyproject.toml. Projects that store tests elsewhere should configure
# `[tool.pytest.ini_options].testpaths` so pytest can find them.
#
# When no tests are detected, the build skips pytest with a message —
# same behavior as the shell build skipping when no .bats files exist.
#
# Usage: build/actions/python/run_tests.sh <path> <use_uv>
#   path:    project directory (already validated)
#   use_uv:  "true" for `uv run pytest`, anything else for `python -m pytest`

set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <path> <use_uv>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
USE_UV="$2"

cd "$INPUT_PATH"

if [[ -d "tests" ]] || [[ -d "test" ]] || grep -qF '[tool.pytest' pyproject.toml 2>/dev/null; then
    if [[ "$USE_UV" == "true" ]]; then
        uv run pytest
    else
        python -m pytest
    fi
else
    printf 'No tests/ or test/ directory and no [tool.pytest] config — skipping pytest\n'
fi
