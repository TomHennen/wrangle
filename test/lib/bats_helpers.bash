#!/usr/bin/env bash
# test/lib/bats_helpers.bash — shared bats helpers, pulled in with `load`.
# Not a test file (no .bats extension), so the suite's *.bats glob skips it.

# skip_or_fail <reason>: under CI the real binary + network are present, so a
# skip means the test silently degraded — fail instead. Locally (CI/
# GITHUB_ACTIONS unset) skip, so sandboxed dev isn't blocked.
skip_or_fail() {
    if [ -n "${CI:-}${GITHUB_ACTIONS:-}" ]; then
        printf 'FATAL: %s (skip not allowed in CI)\n' "$1" >&2
        exit 1
    fi
    skip "$1"
}
