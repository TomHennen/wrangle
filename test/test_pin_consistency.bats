#!/usr/bin/env bats

# Divergence guard for adopter-facing wrangle release pins.
#
# Every example workflow and per-build-type README carries its own
# `uses: TomHennen/wrangle/...@vX.Y.Z # zizmor: ignore[unpinned-uses] - immutable` pin, and
# nothing single-sources the version. A release that bumps some pins but not all
# hands adopters a stale wrangle on copy-paste, with no signal. This fails closed
# when the pins disagree on the version.
#
# wrangle's release tags are immutable, so a tag pin is safe; the inline zizmor
# ignore keeps an adopter's own `unpinned-uses` from firing on the wrangle line.
# A SHA pin (`@<40-hex> # vX.Y.Z`) is also accepted. Excluded: wrangle's internal
# self-references (`# main YYYY-MM-DD`) and the `git+https://...@vX` policy
# locators (no `uses:`). NOT excluded: test fixtures — the grep is repo-wide, so
# a fixture must interpolate its version rather than embed a literal pin.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
    # `uses: <org>/wrangle/<path>@vX.Y.Z`. Org match is case-insensitive
    # (docs mix `TomHennen` and `tomhennen`).
    PIN_RE='uses: [a-z]+/wrangle/[^@[:space:]]+@v[0-9]+\.[0-9]+\.[0-9]+'
    export PIN_RE
}

@test "adopter-facing wrangle release pins all name the same version" {
    local vers
    vers="$(grep -rhoiIE "$PIN_RE" --exclude-dir=.git "$REPO_ROOT" \
        | grep -oiE '@v[0-9]+\.[0-9]+\.[0-9]+' | sort -u)"

    # Non-empty guards against the regex silently rotting to nothing.
    [ -n "$vers" ]

    local count
    count="$(printf '%s\n' "$vers" | wc -l | tr -d ' ')"
    if [ "$count" -ne 1 ]; then
        printf 'Divergent wrangle release pins (expected one version tag):\n%s\n' "$vers" >&2
        grep -rniIE "$PIN_RE" --exclude-dir=.git "$REPO_ROOT" >&2
        return 1
    fi
}

@test "adopter-facing wrangle refs are SHA-pinned or tag-pinned with a zizmor ignore" {
    # Adopter-facing wrangle refs must be a 40-hex SHA pin, or a release-tag pin
    # carrying the inline `# zizmor: ignore[unpinned-uses] - immutable` — wrangle's tags are
    # immutable, so the ignore is safe. A bare tag, a branch, or `@main` trips an
    # adopter's own unpinned-uses on first run. The example files are scanned by
    # test_examples_scan.bats; README/FAQ snippets are markdown and aren't, so
    # this catches the snippets too.
    #
    # Excluded: test/ fixtures (synthetic pins), the @__WRANGLE_SHA__ integration
    # template token, and @<...> doc placeholders.
    local bad
    bad="$(grep -rniIE 'uses: [a-z]+/wrangle/[^@[:space:]]+@[^[:space:]]+' \
            --exclude-dir=.git --exclude-dir=test "$REPO_ROOT" \
        | grep -viE '# *zizmor: *ignore' \
        | grep -viE '@[0-9a-f]{40}([[:space:]]|#|$)' \
        | grep -viE '@<[^>]+>' \
        | grep -viE '@__[A-Za-z_]+__' || true)"

    if [ -n "$bad" ]; then
        printf 'Adopter-facing wrangle refs must be a SHA pin or a tag pin with a zizmor ignore:\n%s\n' "$bad" >&2
        return 1
    fi
}
