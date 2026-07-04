#!/usr/bin/env bats

# Unit tests for tools/check_pin_freshness.sh. Hermetic: each test builds a
# throwaway git repo so the assertions never depend on wrangle's real history.

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/check_pin_freshness.sh"
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO/.github/workflows"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name test
    git -C "$REPO" config commit.gpgsign false
}

commit() {
    git -C "$1" commit -q --allow-empty -m "$2"
    git -C "$1" rev-parse HEAD
}

# write_verify <body> — commit actions/verify with the given script body, print sha
write_verify() {
    mkdir -p "$REPO/actions/verify"
    printf 'name: verify\n' > "$REPO/actions/verify/action.yml"
    printf '%s\n' "$1" > "$REPO/actions/verify/run.sh"
    git -C "$REPO" add actions/verify
    git -C "$REPO" commit -q -m verify
    git -C "$REPO" rev-parse HEAD
}

run_fresh() { run bash -c "cd '$REPO' && '$SCRIPT'"; }

@test "check_pin_freshness: PASSES when a single-level pin resolves to HEAD content" {
    local v; v="$(write_verify 'echo hi')"
    printf '      - uses: TomHennen/wrangle/actions/verify@%s # pin\n' "$v" \
        > "$REPO/.github/workflows/x.yml"
    run_fresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"resolve to HEAD content"* ]]
}

@test "check_pin_freshness: FAILS on a stale-but-reachable pin (path content changed after the pin)" {
    # The #558 shape: verify/run.sh changes after the pin; verify@old is still an
    # ancestor (ancestry would pass) but resolves OLD code.
    local old; old="$(write_verify 'echo OLD')"
    write_verify 'echo NEW' >/dev/null   # HEAD advances; pin still names old
    printf '      - uses: TomHennen/wrangle/actions/verify@%s # pin\n' "$old" \
        > "$REPO/.github/workflows/x.yml"
    # Ancestry holds: old is an ancestor of HEAD.
    run bash -c "cd '$REPO' && '$(dirname "$SCRIPT")/check_pin_ancestry.sh'"
    [ "$status" -eq 0 ]
    run_fresh
    [ "$status" -eq 1 ]
    [[ "$output" == *STALE* ]]
    [[ "$output" == *"actions/verify"* ]]
}

@test "check_pin_freshness: catches a script change even when action.yml is byte-identical" {
    # #558 precisely: verify/action.yml never moved, but run.sh did. An
    # action.yml-only check would false-green here; the whole-tree diff catches it.
    mkdir -p "$REPO/actions/verify"
    printf 'name: verify\n' > "$REPO/actions/verify/action.yml"
    printf 'echo OLD\n' > "$REPO/actions/verify/run.sh"
    git -C "$REPO" add actions/verify && git -C "$REPO" commit -q -m v1
    local old; old="$(git -C "$REPO" rev-parse HEAD)"
    printf 'echo NEW\n' > "$REPO/actions/verify/run.sh"  # action.yml untouched
    git -C "$REPO" commit -qam v2
    printf '      - uses: TomHennen/wrangle/actions/verify@%s # pin\n' "$old" \
        > "$REPO/.github/workflows/x.yml"
    [ "$(git -C "$REPO" show "$old:actions/verify/action.yml")" = "$(git -C "$REPO" show HEAD:actions/verify/action.yml)" ]
    run_fresh
    [ "$status" -eq 1 ]
    [[ "$output" == *STALE* ]]
}

@test "check_pin_freshness: walks a 2-level chain and flags the stale nested pin" {
    # workflow -> release@r (fresh) -> verify@old (stale): verify changed after
    # the nested pin, so the chain is reachable but resolves OLD verify code. The
    # transitive walk must descend release@r and flag the nested verify pin.
    local old; old="$(write_verify 'echo OLD')"
    write_verify 'echo NEW' >/dev/null
    mkdir -p "$REPO/actions/release"
    printf 'name: release\n' > "$REPO/actions/release/action.yml"
    printf '      - uses: TomHennen/wrangle/actions/verify@%s # pin\n' "$old" \
        >> "$REPO/actions/release/action.yml"
    git -C "$REPO" add actions/release && git -C "$REPO" commit -q -m release
    local r; r="$(git -C "$REPO" rev-parse HEAD)"
    printf '      - uses: TomHennen/wrangle/actions/release@%s # pin\n' "$r" \
        > "$REPO/.github/workflows/x.yml"
    # release@r is fresh (its dir is unchanged at HEAD); only nested verify is stale.
    run_fresh
    [ "$status" -eq 1 ]
    [[ "$output" == *"STALE: actions/verify"* ]]
    [[ "$output" != *"STALE: actions/release"* ]]
}

@test "check_pin_freshness: FAILS when a composite retargets a nested pin to a different path" {
    # release@old wires actions/verify; HEAD's release wires actions/other. The
    # pin is reachable and each nested target is itself unchanged, but the parent
    # resolves DIFFERENT wiring — a path retarget, not a sha bump, so it is STALE.
    local v; v="$(write_verify 'echo hi')"
    mkdir -p "$REPO/actions/other"
    printf 'name: other\n' > "$REPO/actions/other/action.yml"
    git -C "$REPO" add actions/other && git -C "$REPO" commit -q -m other
    local o; o="$(git -C "$REPO" rev-parse HEAD)"

    mkdir -p "$REPO/actions/release"
    printf 'name: release\n' > "$REPO/actions/release/action.yml"
    printf '      - uses: TomHennen/wrangle/actions/verify@%s # pin\n' "$v" \
        >> "$REPO/actions/release/action.yml"
    git -C "$REPO" add actions/release && git -C "$REPO" commit -q -m 'release wires verify'
    local rel_old; rel_old="$(git -C "$REPO" rev-parse HEAD)"

    printf 'name: release\n' > "$REPO/actions/release/action.yml"
    printf '      - uses: TomHennen/wrangle/actions/other@%s # pin\n' "$o" \
        >> "$REPO/actions/release/action.yml"
    git -C "$REPO" add actions/release && git -C "$REPO" commit -q -m 'release retargets to other'

    printf '      - uses: TomHennen/wrangle/actions/release@%s # pin\n' "$rel_old" \
        > "$REPO/.github/workflows/x.yml"
    # Ancestry holds; freshness must catch the retarget.
    run bash -c "cd '$REPO' && '$(dirname "$SCRIPT")/check_pin_ancestry.sh'"
    [ "$status" -eq 0 ]
    run_fresh
    [ "$status" -eq 1 ]
    [[ "$output" == *"STALE: actions/release"* ]]
}

@test "check_pin_freshness: PASSES (no-op) on an older pin whose path never changed" {
    # A pin at an older sha is FRESH if its path is byte-identical to HEAD's —
    # don't false-positive just because the sha is old.
    local v; v="$(write_verify 'echo hi')"
    commit "$REPO" "unrelated later commit" >/dev/null  # touches nothing under verify/
    printf '      - uses: TomHennen/wrangle/actions/verify@%s # pin\n' "$v" \
        > "$REPO/.github/workflows/x.yml"
    run_fresh
    [ "$status" -eq 0 ]
}

@test "check_pin_freshness: ignores third-party pins" {
    # Only TomHennen/wrangle self-refs are checked; a stale-looking third-party
    # ref must not be resolved or flagged.
    local v; v="$(write_verify 'echo hi')"
    printf '      - uses: TomHennen/wrangle/actions/verify@%s # pin\n' "$v" \
        > "$REPO/.github/workflows/x.yml"
    printf '      - uses: actions/checkout@%s # third party\n' \
        "0000000000000000000000000000000000000000" >> "$REPO/.github/workflows/x.yml"
    run_fresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 wrangle self-ref pin"* ]]
}

@test "check_pin_freshness: FAILS when the pinned sha is missing (shallow clone)" {
    write_verify 'echo hi' >/dev/null
    printf '      - uses: TomHennen/wrangle/actions/verify@%s # pin\n' \
        "0000000000000000000000000000000000000000" > "$REPO/.github/workflows/x.yml"
    run_fresh
    [ "$status" -eq 1 ]
    [[ "$output" == *MISSING* ]]
}

@test "check_pin_freshness: PASSES (no-op) when there are no wrangle pins" {
    commit "$REPO" A >/dev/null
    printf 'jobs: {}\n' > "$REPO/.github/workflows/x.yml"
    run_fresh
    [ "$status" -eq 0 ]
}
