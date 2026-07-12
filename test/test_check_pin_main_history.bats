#!/usr/bin/env bats

# Unit tests for tools/check_pin_main_history.sh. Hermetic: each test builds a
# throwaway git repo with a `main` branch so the assertions never depend on
# wrangle's real history. No `origin` remote exists, so the script's base-ref
# resolution falls back to the local `main` branch.

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/check_pin_main_history.sh"
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO/.github/workflows"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name test
    git -C "$REPO" config commit.gpgsign false
    git -C "$REPO" checkout -q -b main 2>/dev/null || git -C "$REPO" checkout -q main
}

# commit <message> -> prints the new commit sha
commit() {
    git -C "$REPO" commit -q --allow-empty -m "$1"
    git -C "$REPO" rev-parse HEAD
}

# merge_branch <name> <message> — branch off HEAD, add a commit, merge it back
# with a merge commit (--no-ff), and print the branch-tip sha (second parent).
merge_branch() {
    git -C "$REPO" checkout -q -b "$1"
    local tip; tip="$(commit "$2")"
    git -C "$REPO" checkout -q main
    git -C "$REPO" merge -q --no-ff -m "merge $1" "$1"
    printf '%s' "$tip"
}

# pin <sha> [<label>] — write a workflow pinning actions/scan at <sha>.
pin() {
    if [[ $# -ge 2 ]]; then
        printf '      - uses: TomHennen/wrangle/actions/scan@%s # %s 2026-01-01\n' "$1" "$2" \
            > "$REPO/.github/workflows/x.yml"
    else
        printf '      - uses: TomHennen/wrangle/actions/scan@%s\n' "$1" \
            > "$REPO/.github/workflows/x.yml"
    fi
}

@test "check_pin_main_history: PASSES when the pin is a first-parent commit labeled main" {
    local a; a="$(commit A)"
    pin "$a" main
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "check_pin_main_history: FAILS when the pin is frozen on a merged side branch" {
    commit A >/dev/null
    local branch_tip; branch_tip="$(merge_branch feature F)"
    pin "$branch_tip" feature
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" == *BRANCH-FROZEN* ]]
    [[ "$output" == *"${branch_tip:0:9}"* ]]
}

@test "check_pin_main_history: FAILS when a first-parent pin is labeled with a branch, not main" {
    local a; a="$(commit A)"
    pin "$a" some-cleanup-branch
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" == *MISLABELED* ]]
}

@test "check_pin_main_history: FAILS when a first-parent pin carries no label at all" {
    local a; a="$(commit A)"
    pin "$a"
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" == *MISLABELED* ]]
}

@test "check_pin_main_history: PASSES (exempt) for an in-flight bootstrap pin not yet on main" {
    # A branch SHA that was never merged is not an ancestor of main, so it is
    # an in-flight bootstrap pin — check_pin_ancestry's concern, not this one.
    commit A >/dev/null
    git -C "$REPO" checkout -q -b bootstrap
    local unmerged; unmerged="$(commit B)"
    git -C "$REPO" checkout -q main
    pin "$unmerged" bootstrap
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "check_pin_main_history: PASSES (no-op) when there are no wrangle pins" {
    commit A >/dev/null
    printf 'jobs: {}\n' > "$REPO/.github/workflows/x.yml"
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 0 ]
}

@test "check_pin_main_history: FAILS on a branch-frozen pin nested in a composite (actions/)" {
    # The declared pin lives in actions/, not .github/workflows/ — the walk must
    # seed from both trees.
    commit A >/dev/null
    local branch_tip; branch_tip="$(merge_branch feature F)"
    mkdir -p "$REPO/actions/scan"
    printf '      - uses: TomHennen/wrangle/tools/zizmor@%s # feature 2026-01-01\n' "$branch_tip" \
        > "$REPO/actions/scan/action.yml"
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" == *BRANCH-FROZEN* ]]
}

@test "check_pin_main_history: ignores placeholders in non-YAML and fixtures/" {
    local a; a="$(commit A)"
    mkdir -p "$REPO/actions/scan" "$REPO/tools/lint/fixtures"
    printf '      - uses: TomHennen/wrangle/tools/zizmor@%s # main 2026-01-01\n' "$a" \
        > "$REPO/actions/scan/action.yml"
    printf 'uses: TomHennen/wrangle/actions/scan@%s # feature 2026-01-01\n' \
        "0000000000000000000000000000000000000000" > "$REPO/tools/example.bats"
    printf '      - uses: TomHennen/wrangle/actions/scan@%s # feature 2026-01-01\n' \
        "1111111111111111111111111111111111111111" > "$REPO/tools/lint/fixtures/bad.yml"
    run bash -c "cd '$REPO' && '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 wrangle self-ref pin(s)"* ]]
}
