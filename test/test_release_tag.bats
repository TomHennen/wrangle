#!/usr/bin/env bats

# release_tag.sh runs after the owner has approved the `release` deployment, so
# it is the last thing standing between a dispatch and an immutable tag. Every
# test asserts that a refusal happens BEFORE `gh release create`.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../tools/release_tag.sh"
    TMP_DIR="$(mktemp -d)"
    STUB_BIN="$TMP_DIR/bin"
    mkdir -p "$STUB_BIN"

    export GH_CALLS="$TMP_DIR/gh-calls"
    : > "$GH_CALLS"

    # gh stub: records every call, and answers the two read queries from env so
    # each test can pose one hostile answer without rewriting the stub.
    cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$*" in
    *"git/matching-refs/tags/"*) printf '%s\n' "${TAG_REFS_JSON:-[]}" ;;
    *"run list --workflow release_gate.yml"*) printf '%s\n' "${GATE_RUNS_JSON:?}" ;;
esac
exit 0
EOF
    chmod +x "$STUB_BIN/gh"
    PATH="$STUB_BIN:$PATH"
    export PATH

    REPO="$TMP_DIR/repo"
    mkdir -p "$REPO/docs/release-notes"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@t.t
    git -C "$REPO" config user.name t
    printf 'x\n' > "$REPO/f"
    printf 'What you get in v9.9.9.\n' > "$REPO/docs/release-notes/v9.9.9.md"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm init
    git -C "$REPO" branch -m main
    git -C "$REPO" remote add origin "$REPO"
    TARGET="$(git -C "$REPO" rev-parse HEAD)"

    export WRANGLE_REPO_ROOT="$REPO"
    export GITHUB_REF="refs/heads/main"
    export GITHUB_REPOSITORY="test/wrangle"
    export GATE_RUNS_JSON="[{\"headSha\":\"$TARGET\",\"status\":\"completed\",\"conclusion\":\"success\"}]"
}

teardown() {
    rm -rf "$TMP_DIR"
}

released() { grep -q "release create" "$GH_CALLS"; }

@test "release_tag: rejects a non-semver version without tagging" {
    run "$SCRIPT" 9.9.9 "$TARGET"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"must be vX.Y.Z"* ]]
    ! released
}

@test "release_tag: rejects a target that is not a 40-hex sha" {
    # The dispatcher's input is untrusted: a ref name here would let the tag
    # land on whatever that ref points at when the workflow ran.
    run "$SCRIPT" v9.9.9 main
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"40-character hex sha"* ]]
    ! released
}

@test "release_tag: refuses to run off a branch other than main" {
    GITHUB_REF="refs/heads/attacker" run "$SCRIPT" v9.9.9 "$TARGET"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"runs on main"* ]]
    ! released
}

@test "release_tag: refuses when the tag already exists locally" {
    git -C "$REPO" tag v9.9.9
    run "$SCRIPT" v9.9.9 "$TARGET"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"already exists"* ]]
    ! released
}

@test "release_tag: refuses when the tag already exists on the remote" {
    # LOAD-BEARING. Tags are immutable; the local clone can be stale, so the
    # remote is the authority on whether the name is free.
    TAG_REFS_JSON='[{"ref":"refs/tags/v9.9.9"}]' run "$SCRIPT" v9.9.9 "$TARGET"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"already exists"* ]]
    ! released
}

@test "release_tag: accepts a tag name that only prefixes an existing tag" {
    # matching-refs is a prefix query: v9.9.9 must not be refused because
    # v9.9.90 exists.
    TAG_REFS_JSON='[{"ref":"refs/tags/v9.9.90"}]' run "$SCRIPT" v9.9.9 "$TARGET" --dry-run
    [[ "$status" -eq 0 ]]
    ! released
}

@test "release_tag: refuses a target that is not on main" {
    local off_main
    git -C "$REPO" checkout -q -b side
    printf 'y\n' > "$REPO/g"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm side
    off_main="$(git -C "$REPO" rev-parse HEAD)"
    git -C "$REPO" checkout -q main
    GATE_RUNS_JSON="[{\"headSha\":\"$off_main\",\"status\":\"completed\",\"conclusion\":\"success\"}]" \
        run "$SCRIPT" v9.9.9 "$off_main"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not on origin/main"* ]]
    ! released
}

@test "release_tag: refuses when the Release Gate ran on a different commit" {
    # LOAD-BEARING. A green gate on main's tip says nothing about the commit
    # being tagged.
    GATE_RUNS_JSON='[{"headSha":"0000000000000000000000000000000000000000","status":"completed","conclusion":"success"}]' \
        run "$SCRIPT" v9.9.9 "$TARGET"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no completed, successful"* ]]
    ! released
}

@test "release_tag: refuses when the Release Gate run is still in progress" {
    GATE_RUNS_JSON="[{\"headSha\":\"$TARGET\",\"status\":\"in_progress\",\"conclusion\":null}]" \
        run "$SCRIPT" v9.9.9 "$TARGET"
    [[ "$status" -ne 0 ]]
    ! released
}

@test "release_tag: refuses when the Release Gate failed on the target" {
    GATE_RUNS_JSON="[{\"headSha\":\"$TARGET\",\"status\":\"completed\",\"conclusion\":\"failure\"}]" \
        run "$SCRIPT" v9.9.9 "$TARGET"
    [[ "$status" -ne 0 ]]
    ! released
}

@test "release_tag: refuses when there are no gate runs at all" {
    GATE_RUNS_JSON='[]' run "$SCRIPT" v9.9.9 "$TARGET"
    [[ "$status" -ne 0 ]]
    ! released
}

@test "release_tag: refuses when the notes file is missing at the target" {
    git -C "$REPO" rm -q docs/release-notes/v9.9.9.md
    git -C "$REPO" commit -qm "drop notes"
    local head; head="$(git -C "$REPO" rev-parse HEAD)"
    GATE_RUNS_JSON="[{\"headSha\":\"$head\",\"status\":\"completed\",\"conclusion\":\"success\"}]" \
        run "$SCRIPT" v9.9.9 "$head"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no release notes"* ]]
    ! released
}

@test "release_tag: refuses whitespace-only notes at the target" {
    printf '\n \t\n' > "$REPO/docs/release-notes/v9.9.9.md"
    git -C "$REPO" commit -qam blank
    local head; head="$(git -C "$REPO" rev-parse HEAD)"
    GATE_RUNS_JSON="[{\"headSha\":\"$head\",\"status\":\"completed\",\"conclusion\":\"success\"}]" \
        run "$SCRIPT" v9.9.9 "$head"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"empty"* ]]
    ! released
}

@test "release_tag: reads the notes from the target, not the working tree" {
    # LOAD-BEARING. The workflow has no access to the operator's disk; notes
    # only count if they are committed at the commit being tagged.
    printf 'uncommitted\n' > "$REPO/docs/release-notes/v9.9.8.md"
    run "$SCRIPT" v9.9.8 "$TARGET"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no release notes"* ]]
    ! released
}

@test "release_tag: dry run verifies everything and creates nothing" {
    run "$SCRIPT" v9.9.9 "$TARGET" --dry-run
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"dry run"* ]]
    ! released
}

@test "release_tag: publishes the Release at the target with the committed notes" {
    run "$SCRIPT" v9.9.9 "$TARGET"
    [[ "$status" -eq 0 ]]
    released
    grep -q -- "--latest" "$GH_CALLS"
    grep -q -- "--target $TARGET" "$GH_CALLS"
    ! grep -q -- "--generate-notes" "$GH_CALLS"
}

@test "release_tag: usage error on missing arguments" {
    run "$SCRIPT" v9.9.9
    [[ "$status" -eq 2 ]]
    ! released
}
