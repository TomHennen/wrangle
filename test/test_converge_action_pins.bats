#!/usr/bin/env bats

# Unit tests for tools/converge_action_pins.sh. Hermetic: each test builds a
# throwaway git repo, so the loop drives real bump_action_pins.sh +
# check_pin_ancestry.sh without touching wrangle's own history.

setup() {
    TOOLS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools"
    SCRIPT="$TOOLS/converge_action_pins.sh"
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO/.github/workflows" "$REPO/actions/comp"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name test
    git -C "$REPO" config commit.gpgsign false
}

commit() {
    git -C "$1" commit -q --allow-empty -m "$2"
    git -C "$1" rev-parse HEAD
}

# pin <workflow-sha> <nested-sha> — point the workflow at comp@<workflow-sha>
# and comp's nested inner at inner@<nested-sha>, in the working tree.
pin() {
    printf '      - uses: TomHennen/wrangle/actions/comp@%s # pin\n' "$1" \
        > "$REPO/.github/workflows/x.yml"
    printf '      - uses: TomHennen/wrangle/actions/inner@%s # pin\n' "$2" \
        > "$REPO/actions/comp/action.yml"
}

count_commits() { git -C "$REPO" rev-list --count HEAD; }

run_converge() { run bash -c "cd '$REPO' && '$SCRIPT'"; }
run_check() { run bash -c "cd '$REPO' && '$TOOLS/check_pin_ancestry.sh'"; }

@test "converge: no-op (0 commits) when already green" {
    local a; a="$(commit "$REPO" A)"
    pin "$a" "$a"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m pins
    local before; before="$(count_commits)"
    run_converge
    [ "$status" -eq 0 ]
    [[ "$output" == *"already converged (0 commits)"* ]]
    [ "$(count_commits)" -eq "$before" ]
}

@test "converge: an orphaned 2-level chain converges in two commits" {
    commit "$REPO" A >/dev/null
    git -C "$REPO" checkout -q -b feature
    local orphan; orphan="$(commit "$REPO" ORPHAN)"
    git -C "$REPO" checkout -q -
    # Simulate the squash merge: both pins point at the now-orphaned branch sha.
    pin "$orphan" "$orphan"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "squash merge"
    local before; before="$(count_commits)"
    run_converge
    [ "$status" -eq 0 ]
    [[ "$output" == *"converged in 2 commit"* ]]
    [[ "$output" == *NOTE* ]]
    [ "$(count_commits)" -eq "$((before + 2))" ]
    run_check
    [ "$status" -eq 0 ]
}

@test "converge: stops at WRANGLE_CONVERGE_MAX_ITERS when the chain needs more" {
    commit "$REPO" A >/dev/null
    git -C "$REPO" checkout -q -b feature
    local orphan; orphan="$(commit "$REPO" ORPHAN)"
    git -C "$REPO" checkout -q -
    pin "$orphan" "$orphan"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "squash merge"
    WRANGLE_CONVERGE_MAX_ITERS=1 run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not converged after 1 commit"* ]]
}

@test "converge: refuses to run with a dirty working tree" {
    local a; a="$(commit "$REPO" A)"
    pin "$a" "$a"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m pins
    printf 'dirty\n' > "$REPO/actions/comp/action.yml"
    run_converge
    [ "$status" -eq 2 ]
    [[ "$output" == *"working tree not clean"* ]]
}
