#!/usr/bin/env bats

# Unit tests for tools/check_catalog_bump_pr.sh — the gate that lets a
# catalog-only bump PR merge without a per-digest human read. Exit 0 must mean
# VERIFIED and nothing else, so most of these assert the ways it refuses.
# Driven over a real throwaway git repo holding the real catalog scripts,
# invoked the way the workflow does (--from-base, against a base-ref worktree).
# Digest resolution is curl-only, so a fake `curl` on PATH stands in for the
# GHCR registry API.

# Files the verifier's own verdict depends on. A catalog-only diff is the only
# shape it may pass, so a change to any of these must never come back VERIFIED.
IMPLEMENTATION_FILES=(
    ".github/workflows/local_build_shell.yml"
    "tools/check_catalog_bump_pr.sh"
    "tools/check_catalog.sh"
    "tools/bump_catalog_to_latest.sh"
    "tools/bump_catalog_digest.sh"
    "tools/open_catalog_bump_pr.sh"
    "lib/read_catalog.sh"
    "lib/catalog_rules.sh"
    "lib/registry.sh"
)

DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
DIGEST_C="sha256:$(printf 'c%.0s' {1..64})"

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    BIN_DIR="$BATS_TEST_TMPDIR/bin"
    REPO="$BATS_TEST_TMPDIR/repo"
    BASE_TREE="$BATS_TEST_TMPDIR/base-ref"
    mkdir -p "$BIN_DIR" "$REPO/tools" "$REPO/lib" "$REPO/.github/workflows"
    export PATH="$BIN_DIR:$PATH"
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }

    # The real scripts; every other implementation file is a stub, present only
    # so a diff can touch it.
    cp "$REPO_ROOT/tools/check_catalog_bump_pr.sh" \
        "$REPO_ROOT/tools/check_catalog.sh" \
        "$REPO_ROOT/tools/bump_catalog_to_latest.sh" \
        "$REPO_ROOT/tools/bump_catalog_digest.sh" "$REPO/tools/"
    cp "$REPO_ROOT/lib/read_catalog.sh" "$REPO_ROOT/lib/catalog_rules.sh" \
        "$REPO_ROOT/lib/registry.sh" "$REPO/lib/"
    printf '# stub\n' >"$REPO/tools/open_catalog_bump_pr.sh"
    printf '# stub\n' >"$REPO/.github/workflows/local_build_shell.yml"

    git -C "$REPO" init -q -b main
    git -C "$REPO" config user.email tester@example.com
    git -C "$REPO" config user.name tester
    git -C "$REPO" config commit.gpgsign false
    write_catalog "$DIGEST_A"
    commit base
    BASE="$HEAD_SHA"
}

teardown() {
    git -C "$REPO" worktree remove --force "$BASE_TREE" 2>/dev/null || true
}

# write_catalog <digest> [extra_json_fields] — one curated osv entry.
write_catalog() {
    printf '{"tools":{"osv":{"kind":"scan","network":"egress"%s,"image":"ghcr.io/tomhennen/wrangle/osv@%s"}}}\n' \
        "${2:-}" "$1" >"$REPO/tools/catalog.json"
}

commit() {
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "$1"
    HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
}

# install_curl — a fake `curl` reading $SHIM_DIGEST / $SHIM_TOKEN_FAIL at run time.
install_curl() {
    cat >"$BIN_DIR/curl" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */token\?*)
      [[ -n "${SHIM_TOKEN_FAIL:-}" ]] && exit 22
      printf '{"token":"t"}\n'; exit 0 ;;
    *manifests/*)
      printf 'HTTP/2 200\r\ndocker-content-digest: %s\r\n\r\n' "${SHIM_DIGEST}"; exit 0 ;;
  esac
done
exit 0
SHIM
    chmod +x "$BIN_DIR/curl"
}

# check — delegate to the base ref's copy, as the workflow does.
check() {
    git -C "$REPO" worktree remove --force "$BASE_TREE" 2>/dev/null || true
    git -C "$REPO" worktree add -q --detach "$BASE_TREE" "$BASE"
    run "$REPO/tools/check_catalog_bump_pr.sh" --from-base "$BASE_TREE" "$BASE" "$HEAD_SHA"
}

# reset_to_base — start a fresh head commit from the base commit.
reset_to_base() {
    git -C "$REPO" checkout -q -B head "$BASE"
}

in_list() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# job_block <workflow> <job> — that job's lines, up to the next top-level job.
job_block() {
    awk -v j="$2" '
        $0 == "  " j ":"                          { in_block=1; print; next }
        in_block && /^  [a-zA-Z][a-zA-Z0-9_-]*:$/ { in_block=0 }
        in_block                                  { print }
    ' "$1"
}

# script_refs <file> — repo-relative tools/ and lib/ scripts the file runs or
# sources. Comment lines are dropped: a script named in prose is not a dependency.
script_refs() {
    local body
    body="$(grep -vE '^[[:space:]]*#' "$1" || true)"
    {
        printf '%s\n' "$body" | grep -oE '(tools|lib)/[a-z0-9_-]+\.sh' || true
        printf '%s\n' "$body" | grep -oE '\$SCRIPT_DIR/[a-z0-9_-]+\.sh' | sed 's|^\$SCRIPT_DIR/|tools/|' || true
    } | sort -u
}

@test "check_catalog_bump_pr: a catalog-only bump to the current :latest verifies" {
    install_curl
    write_catalog "$DIGEST_B"
    commit bump
    SHIM_DIGEST="$DIGEST_B" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERIFIED"* ]]
}

@test "check_catalog_bump_pr: a digest that is not the current :latest fails" {
    install_curl
    write_catalog "$DIGEST_B"
    commit bump
    SHIM_DIGEST="$DIGEST_C" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"not the registry current :latest"* ]]
}

@test "check_catalog_bump_pr: an unreachable registry fails closed" {
    install_curl
    write_catalog "$DIGEST_B"
    commit bump
    SHIM_TOKEN_FAIL=1 check
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not resolve every :latest digest"* ]]
}

# The threat this gate exists for. Every file the verdict depends on must stay
# outside what a verifiable diff may touch, so relaxing the gate to admit any of
# them breaks this test rather than shipping silently.
@test "check_catalog_bump_pr: no implementation file can ride along with the bump" {
    install_curl
    [ "${#IMPLEMENTATION_FILES[@]}" -gt 0 ]
    for f in "${IMPLEMENTATION_FILES[@]}"; do
        reset_to_base
        [ -f "$REPO/$f" ]
        write_catalog "$DIGEST_B"
        printf '\n# tampered\n' >>"$REPO/$f"
        commit "bump plus $f"
        SHIM_DIGEST="$DIGEST_B" check
        [ "$status" -eq 1 ] || { printf 'expected refusal for %s, got %s\n' "$f" "$status" >&2; return 1; }
        [[ "$output" == *"NOT VERIFIED"* ]]
    done
}

# Closure check: the workflow declaring the verdict job, plus every script
# reachable from it, must be protected. A job that moves to another workflow, or
# a new helper script, fails here instead of quietly widening what a VERIFIED
# diff may rewrite.
@test "check_catalog_bump_pr: the whole implementation of the verdict is protected" {
    local wf="" cand cur ref queue=() seen=" "
    for cand in "$REPO_ROOT"/.github/workflows/*.yml; do
        if grep -qE '^  catalog-bump-verified:' "$cand"; then
            wf="${cand#"$REPO_ROOT"/}"
        fi
    done
    [ -n "$wf" ]
    in_list "$wf" "${IMPLEMENTATION_FILES[@]}"

    job_block "$REPO_ROOT/$wf" catalog-bump-verified >"$BATS_TEST_TMPDIR/block"
    while IFS= read -r ref; do
        queue+=("$ref")
    done < <(script_refs "$BATS_TEST_TMPDIR/block")
    [ "${#queue[@]}" -gt 0 ]

    while [ "${#queue[@]}" -gt 0 ]; do
        cur="${queue[0]}"
        queue=("${queue[@]:1}")
        case "$seen" in *" $cur "*) continue ;; esac
        seen="$seen$cur "
        if ! in_list "$cur" "${IMPLEMENTATION_FILES[@]}"; then
            printf '%s renders the catalog-bump verdict but is not protected\n' "$cur" >&2
            return 1
        fi
        while IFS= read -r ref; do
            if [ -f "$REPO_ROOT/$ref" ]; then
                queue+=("$ref")
            fi
        done < <(script_refs "$REPO_ROOT/$cur")
    done
    # The closure must have reached past the entrypoint into its helpers.
    [[ "$seen" == *"tools/check_catalog.sh"* && "$seen" == *"lib/registry.sh"* ]]
}

@test "check_catalog_bump_pr: a base ref shipping no verifier fails" {
    install_curl
    write_catalog "$DIGEST_B"
    commit bump
    git -C "$REPO" worktree add -q --detach "$BASE_TREE" "$BASE"
    rm "$BASE_TREE/tools/check_catalog_bump_pr.sh"
    SHIM_DIGEST="$DIGEST_B" run "$REPO/tools/check_catalog_bump_pr.sh" \
        --from-base "$BASE_TREE" "$BASE" "$HEAD_SHA"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ships no executable verifier"* ]]
}

@test "check_catalog_bump_pr: a non-executable verifier on the base ref fails" {
    install_curl
    write_catalog "$DIGEST_B"
    commit bump
    git -C "$REPO" worktree add -q --detach "$BASE_TREE" "$BASE"
    chmod -x "$BASE_TREE/tools/check_catalog_bump_pr.sh"
    SHIM_DIGEST="$DIGEST_B" run "$REPO/tools/check_catalog_bump_pr.sh" \
        --from-base "$BASE_TREE" "$BASE" "$HEAD_SHA"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ships no executable verifier"* ]]
}

@test "check_catalog_bump_pr: a non-executable helper is an environment error" {
    install_curl
    write_catalog "$DIGEST_B"
    commit bump
    git -C "$REPO" worktree add -q --detach "$BASE_TREE" "$BASE"
    chmod -x "$BASE_TREE/tools/bump_catalog_to_latest.sh"
    SHIM_DIGEST="$DIGEST_B" run "$REPO/tools/check_catalog_bump_pr.sh" \
        --from-base "$BASE_TREE" "$BASE" "$HEAD_SHA"
    [ "$status" -eq 2 ]
    [[ "$output" == *"non-executable helper"* ]]
}

@test "check_catalog_bump_pr: a capability grant riding along with the digest fails" {
    install_curl
    write_catalog "$DIGEST_B" ',"secret":"github-token"'
    commit "bump plus secret grant"
    SHIM_DIGEST="$DIGEST_B" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"more than curated image digests"* ]]
}

@test "check_catalog_bump_pr: an image off the curated namespace fails" {
    install_curl
    printf '{"tools":{"osv":{"kind":"scan","network":"egress","image":"registry.example.com/x/osv@%s"}}}\n' \
        "$DIGEST_B" >"$REPO/tools/catalog.json"
    commit "off-namespace"
    SHIM_DIGEST="$DIGEST_B" check
    [ "$status" -eq 1 ]
    [[ "$output" == *"off the curated namespace"* ]]
}

@test "check_catalog_bump_pr: wrong argument count is a usage error" {
    run "$REPO/tools/check_catalog_bump_pr.sh" "$BASE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
    run "$REPO/tools/check_catalog_bump_pr.sh" --from-base "$BASE_TREE" "$BASE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}
