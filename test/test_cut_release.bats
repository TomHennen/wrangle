#!/usr/bin/env bats

# The tag is immutable and there is no undo, so what matters is that every
# refusal path aborts BEFORE the release workflow is dispatched. Each test
# asserts the stub was never asked to dispatch.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../tools/cut_release.sh"
    TMP_DIR="$(mktemp -d)"
    STUB_BIN="$TMP_DIR/bin"
    mkdir -p "$STUB_BIN"

    # A gh stub that records every call and answers the polls with a green gate
    # run. If a dispatch is ever reached on a path that should have refused, the
    # assertion below catches it.
    cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$*" in
    *"run list --workflow release_gate.yml"*) printf '111\n' ;;
    *"run list --workflow release.yml"*)
        # A new run id only after the dispatch, so the script's "a run that
        # isn't the one I saw before" poll terminates.
        if grep -q "workflow run release.yml" "$GH_CALLS"; then printf '222\n'; else printf '111\n'; fi
        ;;
    *"run view 111 --json status"*) printf 'completed\n' ;;
    *"run view 111 --json conclusion"*) printf 'success\n' ;;
    *"run view 222 --json url"*) printf 'https://github.test/run/222\n' ;;
    *"environments/release/deployment-branch-policies"*) printf '%s\n' "${ENV_BRANCHES_JSON:?}" ;;
    *"environments/release"*) printf '%s\n' "${ENV_JSON:?}" ;;
esac
exit 0
EOF
    chmod +x "$STUB_BIN/gh"

    # Polling sleeps would make every happy-path test a multi-second wait.
    printf '#!/bin/bash\nexit 0\n' > "$STUB_BIN/sleep"
    chmod +x "$STUB_BIN/sleep"
    export GH_CALLS="$TMP_DIR/gh-calls"
    : > "$GH_CALLS"
    PATH="$STUB_BIN:$PATH"
    export PATH

    # The companion-pin check talks to the companion repo; stub it so the
    # local refusal paths under test are the only thing that can fail.
    SHOWCASE_STUB="$TMP_DIR/check_pin.sh"
    cat > "$SHOWCASE_STUB" <<'EOF'
#!/bin/bash
exit "${SHOWCASE_PIN_STATUS:-0}"
EOF
    chmod +x "$SHOWCASE_STUB"
    export WRANGLE_SHOWCASE_SCRIPT="$SHOWCASE_STUB"

    # The configured state of the `release` environment: owner-reviewed, main only.
    export ENV_JSON='{"protection_rules":[{"type":"required_reviewers"}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
    export ENV_BRANCHES_JSON='{"branch_policies":[{"name":"main"}]}'

    # A real git repo so the tag/ancestry/notes checks operate on something.
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
    export WRANGLE_REPO_ROOT="$REPO"
}

teardown() {
    rm -rf "$TMP_DIR"
}

dispatched() { grep -q "workflow run release.yml" "$GH_CALLS"; }

@test "cut_release: rejects a non-semver version without dispatching" {
    run "$SCRIPT" 0.4.0
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"must be vX.Y.Z"* ]]
    ! dispatched
}

@test "cut_release: refuses when the notes file is missing at the target" {
    git -C "$REPO" rm -q docs/release-notes/v9.9.9.md
    git -C "$REPO" commit -qm "drop notes"
    run "$SCRIPT" v9.9.9
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no release notes"* ]]
    ! dispatched
}

@test "cut_release: refuses a whitespace-only notes file without dispatching" {
    # LOAD-BEARING. The runbook wants hand-written benefit-first prose and
    # explicitly rejects --generate-notes; an empty file is a wiring error.
    printf '\n  \n\t\n' > "$REPO/docs/release-notes/v9.9.9.md"
    git -C "$REPO" commit -qam "blank notes"
    run "$SCRIPT" v9.9.9
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"empty"* ]]
    ! dispatched
}

@test "cut_release: refuses when the tag already exists" {
    # LOAD-BEARING. Tags are immutable; re-cutting one must never be attempted.
    git -C "$REPO" tag v9.9.9
    run "$SCRIPT" v9.9.9
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"already exists"* ]]
    ! dispatched
}

@test "cut_release: usage error on missing arguments" {
    run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    ! dispatched
}

@test "cut_release: refuses a target that is not origin/main's HEAD" {
    # REGRESSION. workflow_dispatch takes a branch ref, never a raw sha (a sha
    # 422s), so the gate can only be dispatched on main — a target that isn't
    # main's HEAD would have the gate verify the wrong commit.
    local ancestor; ancestor="$(git -C "$REPO" rev-parse HEAD)"
    printf 'z\n' > "$REPO/f2"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm newer
    run "$SCRIPT" v9.9.9 --target "$ancestor"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"HEAD"* ]]
    ! dispatched
}

@test "cut_release: refuses when the companion showcase pins another release" {
    # The post-release showcase run is the only thing that exercises the tag;
    # pinned at the previous release it would exercise that one instead.
    SHOWCASE_PIN_STATUS=1 run "$SCRIPT" v9.9.9
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"companion showcase"* ]]
    ! dispatched
}

@test "cut_release: refuses when the release environment allows every branch" {
    # LOAD-BEARING. An unrestricted environment lets a branch copy of the
    # workflow raise the same approval prompt, and the prompt does not show the
    # ref the approver is approving.
    ENV_JSON='{"protection_rules":[{"type":"required_reviewers"}],"deployment_branch_policy":null}' \
        run "$SCRIPT" v9.9.9
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"allows every branch"* ]]
    ! dispatched
}

@test "cut_release: refuses when the release environment deploys from more than main" {
    ENV_BRANCHES_JSON='{"branch_policies":[{"name":"main"},{"name":"release/*"}]}' \
        run "$SCRIPT" v9.9.9
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"restrict it to main"* ]]
    ! dispatched
}

@test "cut_release: refuses when the release environment has no required reviewer" {
    # LOAD-BEARING. Without a reviewer the tag job would publish unapproved.
    ENV_JSON='{"protection_rules":[],"deployment_branch_policy":{"custom_branch_policies":true}}' \
        run "$SCRIPT" v9.9.9
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no required reviewer"* ]]
    ! dispatched
}

@test "cut_release: dispatches the release workflow and never creates a release itself" {
    # LOAD-BEARING. The script's whole job is to hand the irreversible step to
    # the environment-gated workflow; it must never tag or release directly.
    run "$SCRIPT" v9.9.9
    [[ "$status" -eq 0 ]]
    dispatched
    grep -q -- "-f version=v9.9.9" "$GH_CALLS"
    grep -q -- "-f target=$(git -C "$REPO" rev-parse HEAD)" "$GH_CALLS"
    grep -q -- "-f dry-run=false" "$GH_CALLS"
    ! grep -q "release create" "$GH_CALLS"
    [[ "$output" == *"approval is waiting"* ]]
}

@test "cut_release: forwards --dry-run to the release workflow" {
    run "$SCRIPT" v9.9.9 --dry-run
    [[ "$status" -eq 0 ]]
    grep -q -- "-f dry-run=true" "$GH_CALLS"
    ! grep -q "release create" "$GH_CALLS"
}
