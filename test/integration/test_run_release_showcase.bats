#!/usr/bin/env bats

# run_release_showcase.sh runs after the release is published, so it cannot
# prevent anything — its value is that it pushes the companion tag only when the
# companion would actually exercise THIS release, and that it reports the
# verdict truthfully.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/run_release_showcase.sh"
    TMP_DIR="$(mktemp -d)"
    STUB_BIN="$TMP_DIR/bin"
    mkdir -p "$STUB_BIN"

    export GH_CALLS="$TMP_DIR/gh-calls"
    export TOKENS_SEEN="$TMP_DIR/gh-tokens"
    export TAG_CREATED="$TMP_DIR/tag-created"
    : > "$GH_CALLS"
    : > "$TOKENS_SEEN"

    cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
printf '%s %s\n' "$*" "${GH_TOKEN:-}" >> "$TOKENS_SEEN"
case "$*" in
    *"contents/.github/workflows/showcase-curated.yml"*) printf '%s\n' "${WORKFLOW_SRC:-}" ;;
    *"git/ref/tags/"*) exit "${TAG_EXISTS_STATUS:-1}" ;;
    *"git/ref/heads/main"*) printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' ;;
    *"git/refs --method POST"*) printf 'created\n' > "$TAG_CREATED" ;;
    *"run list"*) printf '%s\n' "${RUN_ID-4242}" ;;
    *"run watch"*) exit "${WATCH_STATUS:-0}" ;;
esac
exit 0
EOF
    chmod +x "$STUB_BIN/gh"
    PATH="$STUB_BIN:$PATH"
    export PATH

    export GH_TOKEN="read-token"
    export COMPANION_PUSH_TOKEN="push-token"
    export WRANGLE_SHOWCASE_POLL_SECONDS=0
    export WRANGLE_SHOWCASE_POLL_ATTEMPTS=2
    export WORKFLOW_SRC
    WORKFLOW_SRC="$(companion_workflow v9.9.9)"
}

# The version is interpolated, never embedded: a literal pin here would join the
# adopter-facing set that test_pin_consistency.bats holds to one version.
companion_workflow() {
    printf 'jobs:\n  go:\n    uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@%s # zizmor: ignore[unpinned-uses] release-tag pin\n' "$1"
}

teardown() {
    rm -rf "$TMP_DIR"
}

tagged() { [[ -f "$TAG_CREATED" ]]; }

# A bare `! cmd` is exempt from set -e unless it is a test's last command, so
# negative assertions return 1 explicitly instead.
refute_tagged() {
    if tagged; then printf 'the companion tag was created\n' >&2; return 1; fi
}

refute_call() {
    if grep -q -- "$1" "$GH_CALLS"; then printf 'unexpected gh call: %s\n' "$1" >&2; return 1; fi
}

@test "run_release_showcase: rejects a non-semver version" {
    run "$SCRIPT" v9.9
    [[ "$status" -eq 2 ]]
    refute_tagged
}

@test "run_release_showcase: usage error with no arguments" {
    run "$SCRIPT"
    [[ "$status" -eq 2 ]]
    refute_tagged
}

@test "run_release_showcase: fails fast when the companion push token is unset" {
    run env -u COMPANION_PUSH_TOKEN "$SCRIPT" v9.9.9
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"COMPANION_PUSH_TOKEN"* ]]
    refute_tagged
}

@test "run_release_showcase: refuses when the companion pins another release" {
    # LOAD-BEARING. A `uses:` ref cannot be an expression, so the companion pin
    # is hand-bumped; unbumped, the run would exercise the previous release and
    # report a green that means nothing about this tag.
    WORKFLOW_SRC="$(companion_workflow v9.9.8)" run "$SCRIPT" v9.9.9
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"v9.9.8"* ]]
    refute_tagged
}

@test "run_release_showcase: refuses when the companion pins no wrangle workflow" {
    WORKFLOW_SRC='jobs: {}' run "$SCRIPT" v9.9.9
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no wrangle pin"* ]]
    refute_tagged
}

@test "run_release_showcase: --check-pin verifies the pin without tagging" {
    run "$SCRIPT" --check-pin v9.9.9
    [[ "$status" -eq 0 ]]
    refute_tagged
    refute_call "run watch"
}

@test "run_release_showcase: --check-pin reports a stale pin" {
    WORKFLOW_SRC="$(companion_workflow v9.9.8)" run "$SCRIPT" --check-pin v9.9.9
    [[ "$status" -eq 1 ]]
    refute_tagged
}

@test "run_release_showcase: pushes the tag and reports a passing run" {
    run "$SCRIPT" v9.9.9
    [[ "$status" -eq 0 ]]
    tagged
    grep -q "ref=refs/tags/v9.9.9" "$GH_CALLS"
    grep -q "run watch 4242" "$GH_CALLS"
}

@test "run_release_showcase: spends the companion push token on the tag push alone" {
    # LOAD-BEARING. Every other call is a public read; the write credential is
    # the one thing here that can change the companion.
    run "$SCRIPT" v9.9.9
    [[ "$status" -eq 0 ]]
    [[ "$(grep -c 'push-token' "$TOKENS_SEEN")" -eq 1 ]]
    grep -qE "git/refs .*--method POST.* push-token$" "$TOKENS_SEEN"
}

@test "run_release_showcase: watches the existing run instead of recreating the tag" {
    # The tag job cannot be re-run, so this one must be re-runnable after a
    # transient failure.
    TAG_EXISTS_STATUS=0 run "$SCRIPT" v9.9.9
    [[ "$status" -eq 0 ]]
    refute_tagged
    grep -q "run watch 4242" "$GH_CALLS"
}

@test "run_release_showcase: fails when the showcase run fails" {
    WATCH_STATUS=1 run "$SCRIPT" v9.9.9
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"did not pass"* ]]
}

@test "run_release_showcase: fails when no showcase run ever appears" {
    RUN_ID='' run "$SCRIPT" v9.9.9
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no showcase-curated.yml run appeared"* ]]
}
