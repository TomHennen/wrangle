#!/usr/bin/env bats

# Divergence guard for adopter-facing wrangle release-tag pins.
#
# Every example workflow and per-build-type README carries its own
# `uses: TomHennen/wrangle/...@vX.Y.Z` pin, and nothing single-sources the
# version. A release that bumps some pins but not all hands adopters a stale
# wrangle on copy-paste, with no signal that anything is wrong. This fails
# closed when the pins disagree.
#
# Scope is the release-tag pins only: SHA self-references (`@<40-hex>`) and the
# `git+https://...@vX` policy locators (which may name any v* tag) are excluded
# by anchoring on `uses: ` and a semver tag.

setup() {
    # Resolve the repo root from this file's location, not git — the test
    # container mounts the repo read-only and runs as a different user than
    # owns the checkout, so a git invocation here would trip git's
    # dubious-ownership guard.
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
    # Match `uses: <org>/wrangle/<path>@vX.Y.Z`. The org needs a
    # case-insensitive scan (`grep -i`): GitHub treats owners that way and the
    # docs mix `TomHennen` and `tomhennen`.
    PIN_RE='uses: [a-z]+/wrangle/[^@[:space:]]+@v[0-9]+\.[0-9]+\.[0-9]+'
    export PIN_RE
}

@test "adopter-facing wrangle tag pins all name the same version" {
    local versions
    versions="$(grep -rhoiIE "$PIN_RE" --exclude-dir=.git "$REPO_ROOT" \
        | grep -oiE 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)"

    # A non-empty result guards against the regex silently rotting to nothing.
    [ -n "$versions" ]

    local count
    count="$(printf '%s\n' "$versions" | wc -l | tr -d ' ')"
    if [ "$count" -ne 1 ]; then
        printf 'Divergent wrangle release-tag pins (expected one version):\n%s\n' "$versions" >&2
        grep -rniIE "$PIN_RE" --exclude-dir=.git "$REPO_ROOT" >&2
        return 1
    fi
}
