#!/usr/bin/env bats

# The tag is immutable and there is no undo, so what matters is that every
# refusal path aborts BEFORE `gh release create` runs. Each test asserts the
# stub was never invoked.

setup() {
    REAL_SCRIPT="$BATS_TEST_DIRNAME/../tools/cut_release.sh"
    TMP_DIR="$(mktemp -d)"
    STUB_BIN="$TMP_DIR/bin"
    mkdir -p "$STUB_BIN"

    # A gh stub that records every call. If `release create` is ever reached on a
    # path that should have refused, the assertion below catches it.
    cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
exit 0
EOF
    chmod +x "$STUB_BIN/gh"
    export GH_CALLS="$TMP_DIR/gh-calls"
    : > "$GH_CALLS"
    PATH="$STUB_BIN:$PATH"
    export PATH

    # cut_release calls its SCRIPT_DIR siblings; stub them so the tests exercise
    # cut_release's own logic, not the real pin checks against a fixture repo.
    mkdir -p "$TMP_DIR/tools"
    cp "$REAL_SCRIPT" "$TMP_DIR/tools/"
    for sib in check_pin_main_history.sh check_pin_freshness.sh; do
        printf '#!/bin/bash\nexit 0\n' > "$TMP_DIR/tools/$sib"
        chmod +x "$TMP_DIR/tools/$sib"
    done
    SCRIPT="$TMP_DIR/tools/cut_release.sh"

    NOTES="$TMP_DIR/notes.md"
    printf 'What you get in v9.9.9.\n' > "$NOTES"

    # A real git repo so the tag/ancestry checks operate on something.
    REPO="$TMP_DIR/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -qb main
    git -C "$REPO" config user.email t@t.t
    git -C "$REPO" config user.name t
    printf 'x\n' > "$REPO/f"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm init
    # A real remote so the script's `git fetch origin` works — without it the
    # fetch fails and every guard "passes" for the wrong reason.
    git -C "$REPO" remote add origin "$REPO"
    git -C "$REPO" update-ref refs/remotes/origin/main HEAD
    export WRANGLE_REPO_ROOT="$REPO"
}

teardown() {
    rm -rf "$TMP_DIR"
}

released() { grep -q "release create" "$GH_CALLS"; }

@test "cut_release: rejects a non-semver version without tagging" {
    run "$SCRIPT" 0.4.0 "$NOTES"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"must be vX.Y.Z"* ]]
    ! released
}

@test "cut_release: refuses a missing notes file without tagging" {
    run "$SCRIPT" v9.9.9 "$TMP_DIR/nope.md"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"notes file not found"* ]]
    ! released
}

@test "cut_release: refuses an empty notes file without tagging" {
    # LOAD-BEARING. The runbook wants hand-written benefit-first prose and
    # explicitly rejects --generate-notes; an empty file is a wiring error.
    : > "$TMP_DIR/empty.md"
    run "$SCRIPT" v9.9.9 "$TMP_DIR/empty.md"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"empty"* ]]
    ! released
}

@test "cut_release: refuses a whitespace-only notes file without tagging" {
    printf '\n  \n\t\n' > "$TMP_DIR/ws.md"
    run "$SCRIPT" v9.9.9 "$TMP_DIR/ws.md"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"whitespace only"* ]]
    ! released
}

@test "cut_release: refuses when the tag already exists" {
    # LOAD-BEARING. Tags are immutable; re-cutting one must never be attempted.
    git -C "$REPO" tag v9.9.9
    run "$SCRIPT" v9.9.9 "$NOTES"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"already exists"* ]]
    ! released
}

@test "cut_release: refuses to cut non-interactively" {
    # LOAD-BEARING. The tag is the owner's call. bats gives no tty, so this also
    # guarantees no test in this suite can ever cut a real release.
    run "$SCRIPT" v9.9.9 "$NOTES" --target HEAD
    [[ "$status" -ne 0 ]]
    ! released
}

@test "cut_release: usage error on missing arguments" {
    run "$SCRIPT" v9.9.9
    [[ "$status" -eq 2 ]]
    ! released
}

@test "cut_release: refuses a target that is not the release branch's HEAD" {
    # REGRESSION. workflow_dispatch takes a branch/tag ref, never a raw sha
    # (`--ref <sha>` is a 422), so the gate can only be dispatched on a branch.
    # If the target isn't that branch's HEAD, the gate would verify a different
    # commit than the one being tagged. Found the hard way: cut_release.sh
    # dispatched `--ref "$target"` and died mid-cut of v0.4.0.
    local ancestor; ancestor="$(git -C "$REPO" rev-parse HEAD)"
    printf 'z\n' > "$REPO/f2"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm newer
    git -C "$REPO" update-ref refs/remotes/origin/main HEAD
    # ancestor IS on origin/main, but is not its HEAD — so it passes the
    # ancestry check and must be caught by the branch-HEAD guard.
    run "$SCRIPT" v9.9.9 "$NOTES" --target "$ancestor"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"HEAD"* ]]
    ! released
}
