#!/usr/bin/env bats

# Unit tests for tools/open_catalog_bump_pr.sh. git runs for real against a
# throwaway repo with a local bare "origin" (no network, faithful to the real
# push); only `gh` is shimmed, recording its argv so we can assert the PR-open
# path without touching GitHub. The shim reports "PR already open" via
# $SHIM_PR_EXISTS so both the create and the update branches are covered.

setup() {
    TOOLS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools"
    SCRIPT="$TOOLS_DIR/open_catalog_bump_pr.sh"
    FRESHNESS="$TOOLS_DIR/check_pin_freshness.sh"
    BIN_DIR="$BATS_TEST_TMPDIR/bin"
    WORK="$BATS_TEST_TMPDIR/work"
    REMOTE="$BATS_TEST_TMPDIR/remote.git"
    GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    mkdir -p "$BIN_DIR"
    export PATH="$BIN_DIR:$PATH"
    export WRANGLE_AUTOBUMP_GH_REPO="tomhennen/wrangle"
    export GH_LOG
    # Local bare "origin" is a filesystem path — keep the token push path (https
    # only) out of these tests so the push is deterministic.
    unset GH_TOKEN

    command -v git >/dev/null 2>&1 || { printf 'git not on PATH\n' >&2; return 1; }

    git init --bare -q "$REMOTE"
    git init -q "$WORK"
    git -C "$WORK" config user.name t
    git -C "$WORK" config user.email t@example.com
    git -C "$WORK" config commit.gpgsign false
    # The repo must carry a converged self-ref pin: open_catalog_bump_pr.sh now
    # converges the pins after the catalog commit, and converge errors on a repo
    # with no pins at all. A workflow pins a verify action at the sha where its
    # tree first appears, so the chain is fresh until the catalog moves.
    mkdir -p "$WORK/tools" "$WORK/actions/verify" "$WORK/.github/workflows" "$WORK/lib"
    printf '{"tools":{}}\n' > "$WORK/tools/catalog.json"
    printf 'name: verify\n' > "$WORK/actions/verify/action.yml"
    printf 'echo hi\n' > "$WORK/actions/verify/run.sh"
    printf 'echo lib\n' > "$WORK/lib/helper.sh"
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm 'init: catalog + verify action + lib'
    local vsha; vsha="$(git -C "$WORK" rev-parse HEAD)"
    printf '      - uses: TomHennen/wrangle/actions/verify@%s # main\n' "$vsha" \
        > "$WORK/.github/workflows/x.yml"
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm 'pin verify'
    git -C "$WORK" branch -M main
    git -C "$WORK" remote add origin "$REMOTE"
    git -C "$WORK" push -q origin main

    cat >"$BIN_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"pr list"*) [[ -n "${SHIM_PR_EXISTS:-}" ]] && printf '1\n' || printf '0\n' ;;
  *"pr create"*) printf 'https://github.com/tomhennen/wrangle/pull/1\n' ;;
esac
exit 0
SHIM
    chmod +x "$BIN_DIR/gh"

    cd "$WORK" || return 1
}

@test "open_catalog_bump_pr: unchanged catalog is a no-op (no branch, no gh)" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to open"* ]]
    [ ! -f "$GH_LOG" ]
    run git -C "$REMOTE" rev-parse --verify bot/catalog-autobump
    [ "$status" -ne 0 ]
}

@test "open_catalog_bump_pr: a bumped catalog is committed, pushed, and a PR opened" {
    printf '{"tools":{"osv":{"image":"x"}}}\n' > "$WORK/tools/catalog.json"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    # Branch pushed to origin with the catalog change.
    git -C "$REMOTE" rev-parse --verify bot/catalog-autobump
    run git -C "$REMOTE" show bot/catalog-autobump:tools/catalog.json
    [[ "$output" == *'"osv"'* ]]
    # gh opened the PR against main.
    grep -q 'pr create' "$GH_LOG"
    grep -q -- '--base main' "$GH_LOG"
    grep -q -- '--head bot/catalog-autobump' "$GH_LOG"
}

@test "open_catalog_bump_pr: converges the pins so the bump branch passes freshness" {
    # The catalog commit stales the consuming pin (freshness folds catalog into
    # scope); the script must converge so the PR is not born red.
    printf '{"tools":{"osv":{"image":"x@sha256:new"}}}\n' > "$WORK/tools/catalog.json"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    # The pushed branch resolves current content: freshness passes on its HEAD.
    git -C "$WORK" checkout -q bot/catalog-autobump
    run bash -c "cd '$WORK' && '$FRESHNESS'"
    [ "$status" -eq 0 ]
    # Catalog commit + at least one convergence commit landed on the branch.
    run git -C "$WORK" rev-list --count main..bot/catalog-autobump
    [ "$output" -ge 2 ]
}

@test "open_catalog_bump_pr: an already-open PR is refreshed, not recreated" {
    printf '{"tools":{"osv":{"image":"x"}}}\n' > "$WORK/tools/catalog.json"
    SHIM_PR_EXISTS=1 run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already open"* ]]
    grep -q 'pr list' "$GH_LOG"
    ! grep -q 'pr create' "$GH_LOG"
    # The force-push still landed the refreshed catalog on the branch.
    git -C "$REMOTE" rev-parse --verify bot/catalog-autobump
}

@test "open_catalog_bump_pr: a second run force-updates the same branch (one rolling PR)" {
    printf '{"tools":{"osv":{"image":"x1"}}}\n' > "$WORK/tools/catalog.json"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    # Next publish: back on main, catalog re-bumped, PR already open.
    git checkout -q main
    printf '{"tools":{"osv":{"image":"x2"}}}\n' > "$WORK/tools/catalog.json"
    SHIM_PR_EXISTS=1 run "$SCRIPT"
    [ "$status" -eq 0 ]
    run git -C "$REMOTE" show bot/catalog-autobump:tools/catalog.json
    [[ "$output" == *'x2'* ]]
}
