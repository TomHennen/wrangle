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
# The discovery decision is split into `should_run_pytest` so test.bats
# can exercise the three discovery branches without a fixture pytest on
# PATH. The function takes the path as an arg and returns 0/1 — pure
# logic about filesystem state, no I/O beyond the test file read.
#
# Usage: build/actions/python/run_tests.sh <path> <use_uv>
#   path:    project directory (already validated)
#   use_uv:  "true" for `uv run pytest`, anything else for `python -m pytest`

set -euo pipefail
set -f

# Pure function: returns 0 (run pytest) if the project has a `tests/` or
# `test/` directory, or a `[tool.pytest` config section in pyproject.toml.
# Returns 1 (skip pytest) otherwise.
#
# Args: <project_dir>
should_run_pytest() {
    local path="$1"
    if [[ -d "$path/tests" ]] || [[ -d "$path/test" ]]; then
        return 0
    fi
    # Match the start-of-line section header to avoid matching a literal
    # `[tool.pytest` substring that happens to appear inside a string
    # value (e.g., a description field).
    if grep -qE '^\[tool\.pytest' "$path/pyproject.toml" 2>/dev/null; then
        return 0
    fi
    return 1
}

main() {
    if [[ $# -ne 2 ]]; then
        printf 'Usage: %s <path> <use_uv>\n' "$0" >&2
        exit 1
    fi

    local input_path="$1"
    local use_uv="$2"

    if should_run_pytest "$input_path"; then
        cd "$input_path"
        if [[ "$use_uv" == "true" ]]; then
            uv run pytest
        else
            python -m pytest
        fi
    else
        printf 'No tests/ or test/ directory and no [tool.pytest] config — skipping pytest\n'
    fi
}

# Sourcing guard: tests source this file to call should_run_pytest
# directly without invoking pytest.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
