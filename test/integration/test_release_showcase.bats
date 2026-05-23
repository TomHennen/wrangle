#!/usr/bin/env bats

# Structural + execution tests for the release-showcase workflow and
# its tag-push script.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WORKFLOW="$REPO_ROOT/.github/workflows/release-showcase.yml"
    SCRIPT="$REPO_ROOT/test/integration/push_showcase_tag.sh"
}

# --- Workflow structural tests ---

@test "release-showcase.yml exists" {
    [[ -f "$WORKFLOW" ]]
}

@test "release-showcase.yml triggers on push to main without a paths filter" {
    # The runtime diff in push_showcase_tag.sh replaces the paths
    # allowlist; the workflow must not reintroduce one.
    run grep -E 'branches:.*main' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep -E '^    paths:' "$WORKFLOW"
    [[ "$status" -ne 0 ]]
}

@test "release-showcase.yml uses environment gating for the cross-repo PAT" {
    run grep 'environment: integration-test' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "release-showcase.yml does not interpolate secrets in run blocks" {
    run grep -P 'run:.*\$\{\{.*secrets\.' "$WORKFLOW"
    [[ "$status" -eq 1 ]]
}

@test "release-showcase.yml passes wrangle SHA through env" {
    run grep 'WRANGLE_SHA:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "release-showcase.yml uses a serializing concurrency group" {
    run grep 'concurrency:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
    run grep 'cancel-in-progress: false' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "release-showcase.yml has a timeout on the job" {
    run grep 'timeout-minutes:' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "release-showcase.yml pins actions to SHAs" {
    run bash -c "grep 'uses:.*@' \"$WORKFLOW\" | grep -v -P '@[0-9a-f]{40}'"
    [[ "$status" -eq 1 ]]
}

@test "release-showcase.yml uses persist-credentials: false on checkout" {
    run grep 'persist-credentials: false' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

@test "release-showcase.yml uses fetch-depth: 0 so the runtime diff can resolve old SHAs" {
    run grep 'fetch-depth: 0' "$WORKFLOW"
    [[ "$status" -eq 0 ]]
}

# --- Script structural tests ---

@test "push_showcase_tag.sh exists and is executable" {
    [[ -x "$SCRIPT" ]]
}

@test "push_showcase_tag.sh starts with set -euo pipefail" {
    run head -3 "$SCRIPT"
    [[ "$output" == *"set -euo pipefail"* ]]
}

@test "push_showcase_tag.sh uses printf not echo for output" {
    run grep -c '^[[:space:]]*echo ' "$SCRIPT"
    [[ "$output" = "0" ]]
}

@test "push_showcase_tag.sh validates WRANGLE_SHA is a full 40-char hex SHA" {
    # Refuses truncated input (the previous code silently truncated to 7).
    run grep -E '\[0-9a-f\]\{40\}' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "push_showcase_tag.sh validates GH_TOKEN is set" {
    run grep 'GH_TOKEN' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "push_showcase_tag.sh derives tag date from commit time, not wall clock" {
    # The bug we fixed: previous version used `date -u +%Y%m%d` which
    # changes across UTC midnight. New version reads %cd from git log.
    run grep -F 'git log -1 --format=%cd' "$SCRIPT"
    [[ "$status" -eq 0 ]]
    # And no wall-clock date call to compose the tag.
    run grep -E 'date -u \+%Y%m%d' "$SCRIPT"
    [[ "$status" -ne 0 ]]
}

@test "push_showcase_tag.sh composes tag as vYYYYMMDD-<sha>" {
    run grep -F 'TAG="v${COMMIT_DATE}-${SHORT_SHA}"' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "push_showcase_tag.sh has a literal-idempotency check (tag already exists)" {
    run grep 'git/ref/tags/' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "push_showcase_tag.sh has runtime-diff short-circuit against last tracking tag" {
    # Replaces the previously hand-maintained paths: allowlist.
    run grep 'matching-refs/tags/' "$SCRIPT"
    [[ "$status" -eq 0 ]]
    run grep 'git diff --quiet' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "push_showcase_tag.sh handles command-substitution failure (no unreachable empty checks)" {
    # Previously had `TARGET_SHA=$(gh ...); if [[ -z $TARGET_SHA ]]`,
    # which was unreachable under set -e + --jq. New form uses if-not
    # on the assignment.
    run grep -E 'if ! TARGET_SHA=' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "push_showcase_tag.sh targets the companion repo's main HEAD" {
    run grep 'git/ref/heads/main' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

@test "push_showcase_tag.sh creates the tag via gh api refs POST" {
    run grep 'git/refs' "$SCRIPT"
    [[ "$status" -eq 0 ]]
    run grep '\-\-method POST' "$SCRIPT"
    [[ "$status" -eq 0 ]]
}

# --- Execution tests with stubbed gh + git ---

# Each execution test sets up an isolated workspace with:
#   - a fresh git repo containing one commit so `git log -1 --format=%cd`
#     works and the input SHA resolves
#   - a PATH-shimmed `gh` whose behavior is set by the GH_STUB_MODE env var
# This exercises code paths beyond `grep` against the file.

_setup_workspace() {
    WORKSPACE="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"

    # Tiny git repo so `git log` and `git diff` have something to chew on.
    (
        cd "$WORKSPACE"
        git init -q -b main
        git -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
            commit -q --allow-empty -m init
    )
    REAL_SHA="$(cd "$WORKSPACE" && git rev-parse HEAD)"

    # The gh stub dispatches off the first arg (api) and the path.
    # Mode is read from GH_STUB_MODE so each test can swap behavior
    # without rewriting the stub.
    cat > "${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$2" in
    "repos/"*"/git/ref/tags/"*)
        case "${GH_STUB_MODE:-}" in
            tag-exists) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    "repos/"*"/git/matching-refs/tags/v")
        case "${GH_STUB_MODE:-}" in
            no-prior-tags) printf '[]' ;;
            *) printf '[]' ;;
        esac
        ;;
    "repos/"*"/git/ref/heads/main")
        # 40-char fake target SHA for wrangle-test/main.
        printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
        ;;
    "repos/"*"/git/refs")
        # Tag-create POST — record that we got here and return success.
        printf 'CREATED\n' > "${GH_STUB_CREATED_MARKER:-/tmp/gh_stub_created}"
        ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "${STUB_DIR}/gh"

    CREATED_MARKER="${WORKSPACE}/.created"
    rm -f "$CREATED_MARKER"

    export PATH="${STUB_DIR}:${PATH}"
    export GH_TOKEN="stub-token"
    export GH_STUB_CREATED_MARKER="$CREATED_MARKER"
}

_teardown_workspace() {
    rm -rf "${WORKSPACE:-/nonexistent}" "${STUB_DIR:-/nonexistent}"
}

@test "push_showcase_tag.sh rejects a non-40-char SHA" {
    run "$SCRIPT" "deadbeef"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"must be a full 40-char hex SHA"* ]]
}

@test "push_showcase_tag.sh rejects a non-hex SHA of correct length" {
    run "$SCRIPT" "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
    [[ "$status" -eq 2 ]]
}

@test "push_showcase_tag.sh fails fast when GH_TOKEN is unset" {
    # Use a valid-format SHA so we get past the format check.
    sha="$(printf 'a%.0s' {1..40})"
    run env -u GH_TOKEN "$SCRIPT" "$sha"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"GH_TOKEN"* ]]
}

@test "push_showcase_tag.sh early-exits when tag already exists" {
    _setup_workspace
    GH_STUB_MODE=tag-exists run bash -c "cd '$WORKSPACE' && '$SCRIPT' '$REAL_SHA'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"already exists"* ]]
    [[ ! -f "$CREATED_MARKER" ]]   # Did not reach the create-tag step.
    _teardown_workspace
}

@test "push_showcase_tag.sh creates the tag when no prior tracking tag exists (bootstrap)" {
    _setup_workspace
    GH_STUB_MODE=no-prior-tags run bash -c "cd '$WORKSPACE' && '$SCRIPT' '$REAL_SHA'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"bootstrapping"* ]]
    [[ "$output" == *"Pushed"* ]]
    [[ -f "$CREATED_MARKER" ]]
    _teardown_workspace
}
