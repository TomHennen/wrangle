#!/usr/bin/env bats

# Unit tests for tools/check_pin_ancestry.sh. Hermetic: each test builds a
# throwaway git repo so the assertions never depend on wrangle's real history.

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/check_pin_ancestry.sh"
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO/.github/workflows"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name test
    git -C "$REPO" config commit.gpgsign false
}

# commit <repo> <message> -> prints the new commit sha
commit() {
    git -C "$1" commit -q --allow-empty -m "$2"
    git -C "$1" rev-parse HEAD
}

# pin_workflow <sha> — write a workflow pinning actions/verify at <sha>
pin_workflow() {
    printf '      - uses: TomHennen/wrangle/actions/verify@%s # pin\n' "$1" \
        > "$REPO/.github/workflows/x.yml"
}

@test "check_pin_ancestry: PASSES when the pin is an ancestor of HEAD" {
    local a; a="$(commit "$REPO" A)"
    commit "$REPO" B >/dev/null
    pin_workflow "$a"
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "check_pin_ancestry: FAILS when a pin is orphaned (not an ancestor of HEAD)" {
    commit "$REPO" A >/dev/null
    git -C "$REPO" checkout -q -b feature
    local b; b="$(commit "$REPO" B)"
    git -C "$REPO" checkout -q -
    commit "$REPO" C >/dev/null   # HEAD advances on the base branch; b is now a sibling
    pin_workflow "$b"
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" == *UNREACHABLE* ]]
}

@test "check_pin_ancestry: FAILS when the pinned sha does not exist (shallow clone / typo)" {
    commit "$REPO" A >/dev/null
    pin_workflow "0000000000000000000000000000000000000000"
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" == *UNREACHABLE* ]]
}

@test "check_pin_ancestry: PASSES (no-op) when there are no wrangle pins" {
    commit "$REPO" A >/dev/null
    printf 'jobs: {}\n' > "$REPO/.github/workflows/x.yml"
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "check_pin_ancestry: FAILS on an orphaned nested pin in a composite (actions/)" {
    # The pin lives in actions/, not .github/workflows/ — the gap that let the
    # scan dispatch break. The walk must reach it.
    commit "$REPO" A >/dev/null
    git -C "$REPO" checkout -q -b feature
    local b; b="$(commit "$REPO" B)"
    git -C "$REPO" checkout -q -
    commit "$REPO" C >/dev/null
    mkdir -p "$REPO/actions/scan"
    printf '      - uses: TomHennen/wrangle/tools/zizmor@%s # pin\n' "$b" \
        > "$REPO/actions/scan/action.yml"
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" == *UNREACHABLE* ]]
}

@test "check_pin_ancestry: validates real YAML pins while ignoring placeholders in non-YAML and fixtures/" {
    # A reachable pin in a composite YAML must be validated; placeholder shas in
    # a .bats file and in a fixtures/ YAML must be skipped. The "1 ... reachable"
    # assertion proves the real pin was actually checked — not that the repo
    # happened to have no pins — so this exercises the filters, not emptiness.
    local a; a="$(commit "$REPO" A)"
    commit "$REPO" B >/dev/null
    mkdir -p "$REPO/actions/scan" "$REPO/tools" "$REPO/tools/lint/fixtures"
    printf '      - uses: TomHennen/wrangle/tools/zizmor@%s # pin\n' "$a" \
        > "$REPO/actions/scan/action.yml"
    printf 'uses: TomHennen/wrangle/actions/scan@%s\n' \
        "0000000000000000000000000000000000000000" > "$REPO/tools/example.bats"
    printf '      - uses: TomHennen/wrangle/actions/scan@%s\n' \
        "1111111111111111111111111111111111111111" > "$REPO/tools/lint/fixtures/bad.yml"
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 wrangle self-ref pin(s) reachable"* ]]
}
