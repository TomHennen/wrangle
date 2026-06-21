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
# and comp's nested inner at inner@<nested-sha>, in the working tree. Both action
# dirs carry a body file so freshness has real tree content to compare (an action
# dir absent at the pinned sha would itself read as stale).
pin() {
    mkdir -p "$REPO/actions/comp" "$REPO/actions/inner"
    printf 'name: inner\n' > "$REPO/actions/inner/action.yml"
    printf '      - uses: TomHennen/wrangle/actions/comp@%s # pin\n' "$1" \
        > "$REPO/.github/workflows/x.yml"
    printf 'name: comp\n' > "$REPO/actions/comp/action.yml"
    printf '      - uses: TomHennen/wrangle/actions/inner@%s # pin\n' "$2" \
        >> "$REPO/actions/comp/action.yml"
}

count_commits() { git -C "$REPO" rev-list --count HEAD; }

run_converge() { run bash -c "cd '$REPO' && '$SCRIPT'"; }
run_check() { run bash -c "cd '$REPO' && '$TOOLS/check_pin_ancestry.sh'"; }
run_fresh() { run bash -c "cd '$REPO' && '$TOOLS/check_pin_freshness.sh'"; }

@test "converge: no-op (0 commits) when already converged (reachable + fresh)" {
    # Seed the action dirs, then drive to a converged baseline so the chain is
    # both reachable and fresh; a second run must then do nothing.
    pin DUMMY DUMMY
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "seed dirs"
    local old; old="$(git -C "$REPO" rev-parse HEAD)"
    pin "$old" "$old"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m pins
    bash -c "cd '$REPO' && '$SCRIPT'" >/dev/null 2>&1   # reach a converged state
    local before; before="$(count_commits)"
    run_converge
    [ "$status" -eq 0 ]
    [[ "$output" == *"already converged (0 commits)"* ]]
    [ "$(count_commits)" -eq "$before" ]
}

@test "converge: a stale-but-reachable nested chain converges to fresh" {
    # comp and inner both exist; the workflow and comp pin an OLD sha whose tree
    # predates a later edit to inner — reachable (ancestry green) but resolving
    # OLD inner content (freshness red). The fresh content is already on HEAD, so
    # one bump cycle re-pins the chain to it.
    pin DUMMY DUMMY
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "seed dirs"
    local old; old="$(git -C "$REPO" rev-parse HEAD)"
    printf 'changed body\n' >> "$REPO/actions/inner/action.yml"  # inner moves after old
    git -C "$REPO" commit -qam "edit inner"
    pin "$old" "$old"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "pin stale chain"
    run_check
    [ "$status" -eq 0 ]   # ancestry green: old is an ancestor (false-green)
    run_fresh
    [ "$status" -eq 1 ]   # freshness red: old resolves stale inner content
    run_converge
    [ "$status" -eq 0 ]
    [[ "$output" == *"converged in 1 commit"* ]]
    run_check
    [ "$status" -eq 0 ]
    run_fresh
    [ "$status" -eq 0 ]
}

@test "converge: a fully-orphaned 2-level chain still needs two commits (squash recovery)" {
    # Both pins point at a now-orphaned branch sha whose tree is absent from main:
    # not reachable AND not fresh. Recovery needs one commit per nesting level —
    # the freshness-aware loop must not regress the ancestry-recovery path.
    pin DUMMY DUMMY
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "seed dirs"
    git -C "$REPO" checkout -q -b feature
    printf 'feature-only\n' >> "$REPO/actions/inner/action.yml"
    git -C "$REPO" commit -qam "feature edit"
    local orphan; orphan="$(git -C "$REPO" rev-parse HEAD)"
    git -C "$REPO" checkout -q -
    pin "$orphan" "$orphan"   # squash-merge shape: pins name the orphaned sha
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "squash merge"
    local before; before="$(count_commits)"
    run_converge
    [ "$status" -eq 0 ]
    [[ "$output" == *"converged in 2 commit"* ]]
    [[ "$output" == *NOTE* ]]
    [ "$(count_commits)" -eq "$((before + 2))" ]
    run_check
    [ "$status" -eq 0 ]
    run_fresh
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

@test "converge: resolves a stale-but-reachable pin that ancestry alone calls green (#552)" {
    # actions/verify changes after the workflow pins it; the pin stays an
    # ancestor (check_pin_ancestry green) but resolves OLD code. Convergence is
    # content-based, so it must bump the pin to the fresh HEAD and stop.
    mkdir -p "$REPO/actions/verify"
    printf 'name: verify\n' > "$REPO/actions/verify/action.yml"
    printf 'echo OLD\n' > "$REPO/actions/verify/run.sh"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m v1
    local old; old="$(git -C "$REPO" rev-parse HEAD)"
    printf '      - uses: TomHennen/wrangle/actions/verify@%s # pin\n' "$old" \
        > "$REPO/.github/workflows/x.yml"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "pin verify@old"
    printf 'echo NEW\n' > "$REPO/actions/verify/run.sh"   # HEAD advances; pin now stale
    git -C "$REPO" commit -qam v2
    # Ancestry passes (false-green), freshness fails — the exact #558 gap.
    run bash -c "cd '$REPO' && '$TOOLS/check_pin_ancestry.sh'"
    [ "$status" -eq 0 ]
    run bash -c "cd '$REPO' && '$TOOLS/check_pin_freshness.sh'"
    [ "$status" -eq 1 ]
    local before; before="$(count_commits)"
    run_converge
    [ "$status" -eq 0 ]
    [[ "$output" == *"converged in 1 commit"* ]]
    [ "$(count_commits)" -eq "$((before + 1))" ]
    run bash -c "cd '$REPO' && '$TOOLS/check_pin_freshness.sh'"
    [ "$status" -eq 0 ]
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
