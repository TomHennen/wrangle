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

@test "no adopter-facing wrangle reference is tag- or branch-pinned" {
    # Adopter-facing wrangle refs must pin a 40-hex SHA: a tag or branch ref
    # (@vX.Y.Z, @main) trips an adopter's own zizmor unpinned-uses on first run.
    # The example files are scanned by test_examples_scan.bats; README/FAQ
    # snippets are markdown and aren't, so this catches the snippets too.
    #
    # Excluded: test/ fixtures (synthetic pins), the @__WRANGLE_SHA__ integration
    # template token, @<...> doc placeholders, and the lone FAQ line that
    # demonstrates the tag form behind an explicit `# zizmor: ignore` escape.
    local bad
    bad="$(grep -rniIE 'uses: [a-z]+/wrangle/[^@[:space:]]+@[^[:space:]]+' \
            --exclude-dir=.git --exclude-dir=test "$REPO_ROOT" \
        | grep -viE '# *zizmor: *ignore' \
        | grep -viE '@[0-9a-f]{40}([[:space:]]|#|$)' \
        | grep -viE '@<[^>]+>' \
        | grep -viE '@__[A-Za-z_]+__' || true)"

    if [ -n "$bad" ]; then
        printf 'Tag/branch-pinned adopter-facing wrangle refs (must be @<40-hex SHA>):\n%s\n' "$bad" >&2
        return 1
    fi
}
