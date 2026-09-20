#!/usr/bin/env bats

# The companion tag is what fires a showcase run, and it is created with the one
# credential that can write to the companion — so what matters is that an
# existing tag is left alone and that a failure to resolve or create never looks
# like success.

setup() {
    LIB="$BATS_TEST_DIRNAME/companion_tag.sh"
    TMP_DIR="$(mktemp -d)"
    STUB_BIN="$TMP_DIR/bin"
    mkdir -p "$STUB_BIN"

    export GH_CALLS="$TMP_DIR/gh-calls"
    : > "$GH_CALLS"

    cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
printf '%s %s\n' "$*" "${GH_TOKEN:-}" >> "$GH_CALLS"
case "$*" in
    *"git/ref/tags/"*) exit "${TAG_EXISTS_STATUS:-1}" ;;
    *"git/ref/heads/main"*)
        if [[ "${MAIN_STATUS:-0}" -ne 0 ]]; then exit "$MAIN_STATUS"; fi
        printf '%s\n' "${MAIN_SHA-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef}"
        ;;
    *"git/refs "*) exit "${CREATE_STATUS:-0}" ;;
esac
exit 0
EOF
    chmod +x "$STUB_BIN/gh"
    PATH="$STUB_BIN:$PATH"
    export PATH
    export GH_TOKEN="read-token"

    # shellcheck source=companion_tag.sh
    source "$LIB"
}

teardown() {
    rm -rf "$TMP_DIR"
}

created() { grep -q -- "--method POST" "$GH_CALLS"; }

# A bare `! cmd` is exempt from set -e unless it is a test's last command, so
# negative assertions return 1 explicitly instead.
refute_created() {
    if created; then printf 'a tag was created\n' >&2; return 1; fi
}

@test "companion_tag: an existing tag is a no-op" {
    TAG_EXISTS_STATUS=0 run companion_create_tag_at_main repo/companion v9.9.9
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"already exists"* ]]
    refute_created
}

@test "companion_tag: creates the tag at the companion's main HEAD" {
    run companion_create_tag_at_main repo/companion v9.9.9
    [[ "$status" -eq 0 ]]
    created
    grep -q "ref=refs/tags/v9.9.9" "$GH_CALLS"
    grep -q "sha=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$GH_CALLS"
}

@test "companion_tag: fails when main HEAD cannot be resolved" {
    MAIN_STATUS=1 run companion_create_tag_at_main repo/companion v9.9.9
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"could not resolve"* ]]
    refute_created
}

@test "companion_tag: fails when main HEAD comes back empty" {
    MAIN_SHA='' run companion_create_tag_at_main repo/companion v9.9.9
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"empty SHA"* ]]
    refute_created
}

@test "companion_tag: fails when the create call fails" {
    # LOAD-BEARING. A silent failure here means no showcase run and no signal.
    CREATE_STATUS=1 run companion_create_tag_at_main repo/companion v9.9.9
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"could not create tag"* ]]
}

@test "companion_tag: spends the given token on the create alone" {
    run companion_create_tag_at_main repo/companion v9.9.9 push-token
    [[ "$status" -eq 0 ]]
    [[ "$(grep -c 'push-token' "$GH_CALLS")" -eq 1 ]]
    grep -qE -- "--method POST.* push-token$" "$GH_CALLS"
}

@test "companion_tag: companion_tag_exists reports both answers" {
    TAG_EXISTS_STATUS=0 run companion_tag_exists repo/companion v9.9.9
    [[ "$status" -eq 0 ]]
    TAG_EXISTS_STATUS=1 run companion_tag_exists repo/companion v9.9.9
    [[ "$status" -ne 0 ]]
}
