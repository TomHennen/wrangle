#!/usr/bin/env bats

# Unit tests for tools/check_catalog_bump_pr.sh — the gate that lets a
# catalog-only bump PR merge without a per-digest human read. Driven over a real
# throwaway git repo holding the real catalog scripts, invoked the way the
# workflow does (from a base-ref worktree). Digest resolution is curl-only, so a
# fake `curl` on PATH stands in for the GHCR registry API.

DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
DIGEST_C="sha256:$(printf 'c%.0s' {1..64})"

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    BIN_DIR="$BATS_TEST_TMPDIR/bin"
    REPO="$BATS_TEST_TMPDIR/repo"
    BASE_TREE="$BATS_TEST_TMPDIR/base-ref"
    mkdir -p "$BIN_DIR" "$REPO/tools" "$REPO/lib"
    export PATH="$BIN_DIR:$PATH"
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }

    cp "$REPO_ROOT/tools/check_catalog_bump_pr.sh" \
        "$REPO_ROOT/tools/check_catalog.sh" \
        "$REPO_ROOT/tools/bump_catalog_to_latest.sh" \
        "$REPO_ROOT/tools/bump_catalog_digest.sh" "$REPO/tools/"
    cp "$REPO_ROOT/lib/read_catalog.sh" "$REPO_ROOT/lib/catalog_rules.sh" \
        "$REPO_ROOT/lib/registry.sh" "$REPO/lib/"

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

# check — run the base ref's copy of the script, as the workflow does.
check() {
    git -C "$REPO" worktree add -q --detach "$BASE_TREE" "$BASE"
    run "$BASE_TREE/tools/check_catalog_bump_pr.sh" "$BASE" "$HEAD_SHA"
}

@test "check_catalog_bump_pr: a catalog-only bump to the current :latest verifies" {
    install_curl
    write_catalog "$DIGEST_B"
    commit bump
    SHIM_DIGEST="$DIGEST_B" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"verified"* ]]
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

# The threat this gate exists for: a change that rewrites the checking tooling
# alongside the catalog is out of scope, so it can never claim a verified bump.
@test "check_catalog_bump_pr: a diff wider than the catalog is out of scope" {
    install_curl
    write_catalog "$DIGEST_B"
    printf '\n# tampered\n' >>"$REPO/tools/check_catalog_bump_pr.sh"
    commit "bump plus tooling"
    SHIM_DIGEST="$DIGEST_B" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"normal review applies"* ]]
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
    git -C "$REPO" worktree add -q --detach "$BASE_TREE" "$BASE"
    run "$BASE_TREE/tools/check_catalog_bump_pr.sh" "$BASE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}
