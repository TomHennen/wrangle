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
