#!/usr/bin/env bats

# Unit tests for tools/wrangle_alert.sh. A fake `gh` on PATH records what it
# was called with and returns fixture issue lists — the test needs
# deterministic "is there already an open alert for this key" state that no
# real API returns on demand, and must prove raise/clear never duplicate or
# double-close.

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/wrangle_alert.sh"
    BIN_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN_DIR"
    export PATH="$BIN_DIR:$PATH"
    CALLS_LOG="$BATS_TEST_TMPDIR/calls.log"
    export CALLS_LOG
    BODY_FILE="$BATS_TEST_TMPDIR/body.txt"
    printf 'the check is red\nsee: https://example/run/1\n' > "$BODY_FILE"
}

# Fake `gh`: `issue list` prints $SHIM_ISSUES (a JSON array of {number,body});
# `issue view --json comments` prints $SHIM_LAST_COMMENT (raw text, as gh's
# own --jq would); `issue view --json body` prints $SHIM_ISSUE_BODY. Every
# invocation is appended to $CALLS_LOG for assertion. Set $SHIM_GH_FAIL to
# make every call fail.
install_gh() {
    cat > "$BIN_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS_LOG:?}"
[[ -n "${SHIM_GH_FAIL:-}" ]] && { printf 'gh: backend unreachable\n' >&2; exit 1; }
if [[ "$1" == "issue" && "$2" == "list" ]]; then
    printf '%s\n' "${SHIM_ISSUES:-[]}"
elif [[ "$1" == "issue" && "$2" == "view" ]]; then
    case " $* " in
        *' --json comments '*) printf '%s' "${SHIM_LAST_COMMENT:-}" ;;
        *' --json body '*) printf '%s' "${SHIM_ISSUE_BODY:-}" ;;
    esac
fi
SHIM
    chmod +x "$BIN_DIR/gh"
}

@test "wrangle_alert: raise opens a new issue when none is open for the key" {
    install_gh
    export SHIM_ISSUES='[]'
    run "$SCRIPT" raise drift "Catalog freshness check is red" "$BODY_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"opened a new"* ]]
    grep -q -- '--label wrangle-alert' "$CALLS_LOG"
    grep -q -- 'issue create' "$CALLS_LOG"
}

@test "wrangle_alert: raise's created issue body carries the key's hidden marker" {
    install_gh
    export SHIM_ISSUES='[]'
    cat > "$BIN_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALLS_LOG:?}"
if [[ "$1" == "issue" && "$2" == "list" ]]; then
    printf '%s\n' "${SHIM_ISSUES:-[]}"
elif [[ "$1" == "issue" && "$2" == "create" ]]; then
    for ((i = 1; i <= $#; i++)); do
        if [[ "${!i}" == "--body-file" ]]; then
            j=$((i + 1))
            cp "${!j}" "${CREATED_BODY:?}"
        fi
    done
fi
SHIM
    chmod +x "$BIN_DIR/gh"
    CREATED_BODY="$BATS_TEST_TMPDIR/created_body.txt"
    export CREATED_BODY
    run "$SCRIPT" raise drift "Catalog freshness check is red" "$BODY_FILE"
    [ "$status" -eq 0 ]
    grep -q -- '<!-- wrangle-alert:drift -->' "$CREATED_BODY"
}

@test "wrangle_alert: raise comments (not duplicates) when an already-open issue's last update differs" {
    install_gh
    export SHIM_ISSUES='[{"number":42,"body":"red\n\n<!-- wrangle-alert:drift -->\n"}]'
    export SHIM_ISSUE_BODY=$'an earlier, different failure\n\n<!-- wrangle-alert:drift -->\n'
    run "$SCRIPT" raise drift "Catalog freshness check is red" "$BODY_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"commented on existing #42"* ]]
    grep -q -- 'issue comment 42' "$CALLS_LOG"
    ! grep -q -- 'issue create' "$CALLS_LOG"
}

@test "wrangle_alert: raise does not comment when the last comment already matches" {
    install_gh
    local last_comment
    last_comment="$(cat "$BODY_FILE")"
    export SHIM_ISSUES='[{"number":42,"body":"red\n\n<!-- wrangle-alert:drift -->\n"}]'
    export SHIM_LAST_COMMENT="$last_comment"
    run "$SCRIPT" raise drift "Catalog freshness check is red" "$BODY_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged since the last update; not commenting"* ]]
    ! grep -q -- 'issue comment' "$CALLS_LOG"
}

@test "wrangle_alert: raise does not comment when the issue body (no prior comments) already matches" {
    install_gh
    local issue_body
    issue_body="$(printf '%s\n\n<!-- wrangle-alert:drift -->\n' "$(cat "$BODY_FILE")")"
    export SHIM_ISSUES='[{"number":42,"body":"red\n\n<!-- wrangle-alert:drift -->\n"}]'
    export SHIM_ISSUE_BODY="$issue_body"
    run "$SCRIPT" raise drift "Catalog freshness check is red" "$BODY_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged since the last update; not commenting"* ]]
    ! grep -q -- 'issue comment' "$CALLS_LOG"
}

@test "wrangle_alert: raising the same failure twice results in exactly one comment total (create, then dedup)" {
    install_gh
    # First raise: no issue open yet -> creates one.
    export SHIM_ISSUES='[]'
    run "$SCRIPT" raise drift "Catalog freshness check is red" "$BODY_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"opened a new"* ]]

    # Second raise, same failure content: the issue is now open with that
    # same content as its body, so this must not add a comment.
    local issue_body
    issue_body="$(printf '%s\n\n<!-- wrangle-alert:drift -->\n' "$(cat "$BODY_FILE")")"
    export SHIM_ISSUES='[{"number":42,"body":"red\n\n<!-- wrangle-alert:drift -->\n"}]'
    export SHIM_ISSUE_BODY="$issue_body"
    run "$SCRIPT" raise drift "Catalog freshness check is red" "$BODY_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not commenting"* ]]

    [ "$(grep -c -- 'issue create' "$CALLS_LOG")" -eq 1 ]
    [ "$(grep -c -- 'issue comment' "$CALLS_LOG")" -eq 0 ]
}

@test "wrangle_alert: raise ignores an open issue for a different key" {
    install_gh
    export SHIM_ISSUES='[{"number":7,"body":"<!-- wrangle-alert:other-check -->"}]'
    run "$SCRIPT" raise drift "Catalog freshness check is red" "$BODY_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"opened a new"* ]]
}

@test "wrangle_alert: clear closes the open issue for the key" {
    install_gh
    export SHIM_ISSUES='[{"number":42,"body":"red\n\n<!-- wrangle-alert:drift -->\n"}]'
    run "$SCRIPT" clear drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"closed #42"* ]]
    grep -q -- 'issue close 42' "$CALLS_LOG"
}

@test "wrangle_alert: clear is a no-op when nothing is open for the key" {
    install_gh
    export SHIM_ISSUES='[]'
    run "$SCRIPT" clear drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"no open"* ]]
    ! grep -q -- 'issue close' "$CALLS_LOG"
}

@test "wrangle_alert: clear never touches an open issue for a different key" {
    install_gh
    export SHIM_ISSUES='[{"number":7,"body":"<!-- wrangle-alert:other-check -->"}]'
    run "$SCRIPT" clear drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"no open"* ]]
    ! grep -q -- 'issue close' "$CALLS_LOG"
}

@test "wrangle_alert: raise rejects an invalid key" {
    run "$SCRIPT" raise "Not_Valid" "title" "$BODY_FILE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid key"* ]]
}

@test "wrangle_alert: clear rejects an invalid key" {
    run "$SCRIPT" clear "UPPERCASE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid key"* ]]
}

@test "wrangle_alert: raise rejects a missing body file" {
    run "$SCRIPT" raise drift "title" "$BATS_TEST_TMPDIR/nope.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"body file not found"* ]]
}

@test "wrangle_alert: raise on a gh listing failure is a backend error (exit 2)" {
    install_gh
    export SHIM_GH_FAIL=1
    run "$SCRIPT" raise drift "title" "$BODY_FILE"
    [ "$status" -eq 2 ]
}

@test "wrangle_alert: clear on a gh listing failure is a backend error (exit 2)" {
    install_gh
    export SHIM_GH_FAIL=1
    run "$SCRIPT" clear drift
    [ "$status" -eq 2 ]
}

@test "wrangle_alert: usage error with no verb" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "wrangle_alert: usage error with wrong arg count for raise" {
    run "$SCRIPT" raise drift "title"
    [ "$status" -eq 1 ]
}

@test "wrangle_alert: usage error with wrong arg count for clear" {
    run "$SCRIPT" clear
    [ "$status" -eq 1 ]
}
