#!/usr/bin/env bats

# The finalize is the step a human forgets, and `bump_action_pins` silently
# labels with the current branch unless WRANGLE_PINS_BRANCH=main is set. Both
# mistakes were made by hand cutting v0.4.0, so both are pinned here.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../tools/finalize_pins.sh"
    TMP_DIR="$(mktemp -d)"
    STUB="$TMP_DIR/bin"
    mkdir -p "$STUB"

    # Record how bump_action_pins is invoked, and with what label.
    cat > "$STUB/bump_action_pins.sh" <<'EOF'
#!/bin/bash
printf 'target=%s label=%s\n' "$1" "${WRANGLE_PINS_BRANCH:-<unset>}" >> "$BUMP_CALLS"
exit 0
EOF
    cat > "$STUB/check_pin_main_history.sh" <<'EOF'
#!/bin/bash
exit "${MAIN_HISTORY_RC:-0}"
EOF
    cat > "$STUB/check_pin_freshness.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$STUB"/*.sh
    export BUMP_CALLS="$TMP_DIR/bump-calls"
    : > "$BUMP_CALLS"

    REPO="$TMP_DIR/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -qb main
    git -C "$REPO" config user.email t@t.t
    git -C "$REPO" config user.name t
    printf 'x\n' > "$REPO/f"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm c1
    git -C "$REPO" remote add origin "$REPO"
    git -C "$REPO" update-ref refs/remotes/origin/main HEAD
    export WRANGLE_REPO_ROOT="$REPO"

    # Run the real script but with stubbed siblings on its SCRIPT_DIR.
    mkdir -p "$TMP_DIR/tools"
    cp "$SCRIPT" "$TMP_DIR/tools/"
    cp "$STUB"/*.sh "$TMP_DIR/tools/"
    RUN="$TMP_DIR/tools/finalize_pins.sh"
}

teardown() { rm -rf "$TMP_DIR"; }

@test "finalize_pins: always labels the pins # main, never the current branch" {
    # LOAD-BEARING. Without WRANGLE_PINS_BRANCH=main, bump_action_pins writes the
    # current branch's name and the pins come out `# some-branch` — the #592
    # footgun, hit by hand while cutting v0.4.0.
    git -C "$REPO" checkout -qb some-feature-branch
    run "$RUN"
    [[ "$status" -eq 0 ]]
    grep -q 'label=main' "$BUMP_CALLS"
    ! grep -q 'some-feature-branch' "$BUMP_CALLS"
}

@test "finalize_pins: refuses a target that is not on main's first-parent history" {
    # LOAD-BEARING. Pinning a branch commit is exactly the state being fixed;
    # accepting one here would silently no-op the finalize.
    git -C "$REPO" checkout -qb side
    printf 'y\n' > "$REPO/g"
    git -C "$REPO" add -A && git -C "$REPO" commit -qm side-commit
    local side; side="$(git -C "$REPO" rev-parse HEAD)"
    run "$RUN" "$side"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"first-parent"* ]]
    [[ ! -s "$BUMP_CALLS" ]]
}

@test "finalize_pins: fails when the pins still aren't on first-parent after the bump" {
    export MAIN_HISTORY_RC=1
    run "$RUN"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"do not cut"* ]]
}

@test "finalize_pins: usage error on extra arguments" {
    run "$RUN" a b
    [[ "$status" -eq 2 ]]
}

@test "finalize_pins: a long first-parent history doesn't SIGPIPE the check" {
    # REGRESSION. The check was `rev-list --first-parent | grep -qx "$sha"`.
    # grep -q exits on the first match — and for HEAD the match IS the first
    # line — so rev-list took SIGPIPE (141) and pipefail turned that into a
    # false "not on first-parent history". It only reproduces when rev-list has
    # more to write after grep exits, i.e. a history longer than a pipe buffer's
    # worth of lines, which the other fixtures are too short to trigger (#771).
    local i
    for ((i = 0; i < 200; i++)); do
        printf '%s\n' "$i" > "$REPO/f"
        git -C "$REPO" add -A
        git -C "$REPO" commit -qm "c$i"
    done
    git -C "$REPO" update-ref refs/remotes/origin/main HEAD
    run "$RUN"
    [[ "$status" -eq 0 ]]
    grep -q 'label=main' "$BUMP_CALLS"
}
