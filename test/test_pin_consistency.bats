#!/usr/bin/env bats

# Divergence guard for adopter-facing wrangle release pins.
#
# Every example workflow and per-build-type README carries its own
# `uses: TomHennen/wrangle/...@<sha> # vX.Y.Z` pin, and nothing single-sources
# the SHA. A release that bumps some pins but not all hands adopters a stale
# wrangle on copy-paste, with no signal. This fails closed when the pins
# disagree on the commit.
#
# Scope is the adopter-facing release pins — anchored on `uses: ` + a 40-hex
# SHA + a `# vX.Y.Z` version comment. Wrangle's internal self-references carry a
# `# main YYYY-MM-DD` comment instead, so they're excluded; the
# `git+https://...@vX` policy locators (no SHA, no `uses:`) are excluded too.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
    # `uses: <org>/wrangle/<path>@<40-hex> # vX.Y.Z`. Org match is
    # case-insensitive (docs mix `TomHennen` and `tomhennen`).
    PIN_RE='uses: [a-z]+/wrangle/[^@[:space:]]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+'
    export PIN_RE
}

@test "adopter-facing wrangle release pins all name the same commit" {
    local shas
    shas="$(grep -rhoiIE "$PIN_RE" --exclude-dir=.git "$REPO_ROOT" \
        | grep -oiE '@[0-9a-f]{40}' | tr -d '@' | sort -u)"

    # Non-empty guards against the regex silently rotting to nothing.
    [ -n "$shas" ]

    local count
    count="$(printf '%s\n' "$shas" | wc -l | tr -d ' ')"
    if [ "$count" -ne 1 ]; then
        printf 'Divergent wrangle release pins (expected one commit SHA):\n%s\n' "$shas" >&2
        grep -rniIE "$PIN_RE" --exclude-dir=.git "$REPO_ROOT" >&2
        return 1
    fi
}
