#!/usr/bin/env bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../tools/bump_version_refs.sh"
    TMP_DIR="$(mktemp -d)"
    export WRANGLE_REPO_ROOT="$TMP_DIR"
    mkdir -p "$TMP_DIR/gh_workflow_examples" "$TMP_DIR/build/actions/go" "$TMP_DIR/docs"
}

teardown() {
    rm -rf "$TMP_DIR"
}

seed_tree() {
    local v="${1:-v0.3.1}"
    printf 'jobs:\n  build:\n    uses: TomHennen/wrangle/.github/workflows/build_go.yml@%s # zizmor: ignore\n' "$v" \
        > "$TMP_DIR/gh_workflow_examples/build_go.yml"
    printf 'Verify:\n\n```\nampel verify \\\n  --policy git+https://github.com/TomHennen/wrangle@%s#policies/wrangle-vsa-consumer-v1.hjson \\\n```\n' "$v" \
        > "$TMP_DIR/build/actions/go/README.md"
}

@test "bump_version_refs: rewrites uses: pins and policy locators together" {
    seed_tree v0.3.1
    run "$SCRIPT" v0.4.0
    [[ "$status" -eq 0 ]]
    grep -q 'build_go.yml@v0.4.0' "$TMP_DIR/gh_workflow_examples/build_go.yml"
    grep -q 'wrangle@v0.4.0#policies/' "$TMP_DIR/build/actions/go/README.md"
    ! grep -rq 'v0\.3\.1' "$TMP_DIR"
}

@test "bump_version_refs: leaves the wrangle-test curated-release example alone" {
    # LOAD-BEARING. The worked example cites a real published artifact; the new
    # release's does not exist until the tag is cut, so rewriting it 404s the docs.
    seed_tree v0.3.1
    printf 'base=https://github.com/TomHennen/wrangle-test/releases/download/v0.3.1\n' \
        > "$TMP_DIR/docs/verifying_artifacts.md"
    run "$SCRIPT" v0.4.0
    [[ "$status" -eq 0 ]]
    grep -q 'wrangle-test/releases/download/v0.3.1' "$TMP_DIR/docs/verifying_artifacts.md"
}

@test "bump_version_refs: never touches a third-party action pinned at the same version" {
    seed_tree v0.3.1
    printf 'steps:\n  - uses: actions/checkout@v0.3.1\n' > "$TMP_DIR/gh_workflow_examples/other.yml"
    run "$SCRIPT" v0.4.0
    [[ "$status" -eq 0 ]]
    grep -q 'actions/checkout@v0.3.1' "$TMP_DIR/gh_workflow_examples/other.yml"
}

@test "bump_version_refs: fails closed when refs already disagree on a version" {
    seed_tree v0.3.1
    printf 'uses: TomHennen/wrangle/actions/scan@v0.2.0\n' > "$TMP_DIR/gh_workflow_examples/stale.yml"
    run "$SCRIPT" v0.4.0
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"disagree on a version"* ]]
    # Nothing rewritten — a partial bump is the exact drift being guarded against.
    grep -q '@v0.3.1' "$TMP_DIR/gh_workflow_examples/build_go.yml"
}

@test "bump_version_refs: rejects a malformed version" {
    seed_tree v0.3.1
    run "$SCRIPT" 0.4.0
    [[ "$status" -eq 2 ]]
    grep -q '@v0.3.1' "$TMP_DIR/gh_workflow_examples/build_go.yml"
}

@test "bump_version_refs: no-ops when already at the target version" {
    seed_tree v0.4.0
    run "$SCRIPT" v0.4.0
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"already at v0.4.0"* ]]
}
