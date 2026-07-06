#!/usr/bin/env bats

# Unit tests for tools/bump_catalog_to_latest.sh — the batch driver behind the
# post-publish auto-bump. Digest resolution is curl-only, so a fake `curl` on
# PATH stands in for the GHCR registry API (same shim shape as the freshness
# test); the write path runs the real bump_catalog_digest.sh, no network.

DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/bump_catalog_to_latest.sh"
    CATALOG="$BATS_TEST_TMPDIR/catalog.json"
    BIN_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN_DIR"
    export WRANGLE_CATALOG="$CATALOG" PATH="$BIN_DIR:$PATH"
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }

    printf '%s\n' \
        '{"tools":{"osv":{"kind":"scan","image":"ghcr.io/tomhennen/wrangle/osv@'"$DIGEST_A"'","network":"egress"}}}' \
        > "$CATALOG"
}

image_of() { jq -r --arg t "$1" '.tools[$t].image' "$CATALOG"; }

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

# install_curl_per_image — toola resolves a drifted digest; toolb's lookup fails.
install_curl_per_image() {
    cat >"$BIN_DIR/curl" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *toolb*) exit 22 ;;
    *token\?*) printf '{"token":"t"}\n'; exit 0 ;;
    *toola/manifests*) printf 'HTTP/2 200\r\ndocker-content-digest: $DIGEST_B\r\n\r\n'; exit 0 ;;
  esac
done
exit 0
SHIM
    chmod +x "$BIN_DIR/curl"
}

@test "bump_catalog_to_latest: drifted digest is bumped to :latest (exit 0)" {
    install_curl
    SHIM_DIGEST="$DIGEST_B" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(image_of osv)" = "ghcr.io/tomhennen/wrangle/osv@$DIGEST_B" ]
    [[ "$output" == *"bumped 1 of 1"* ]]
}

@test "bump_catalog_to_latest: in-sync digest is a no-op (exit 0)" {
    install_curl
    SHIM_DIGEST="$DIGEST_A" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(image_of osv)" = "ghcr.io/tomhennen/wrangle/osv@$DIGEST_A" ]
    [[ "$output" == *"bumped 0 of 1"* ]]
}

@test "bump_catalog_to_latest: adopter-override entry is skipped" {
    # Token-fail shim: a resolved non-curated entry would surface as exit 2.
    install_curl
    printf '%s\n' \
        '{"tools":{"adopter":{"kind":"scan","image":"registry.example.com/x/y@'"$DIGEST_A"'"}}}' \
        > "$CATALOG"
    SHIM_TOKEN_FAIL=1 run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bumped 0 of 0"* ]]
}

# A resolvable entry is still bumped even when a sibling's registry lookup fails,
# and the overall run reports the backend error (exit 2).
@test "bump_catalog_to_latest: resolvable entry bumped despite a sibling backend error (exit 2)" {
    install_curl_per_image
    printf '%s\n' \
        '{"tools":{"toola":{"kind":"scan","image":"ghcr.io/tomhennen/wrangle/toola@'"$DIGEST_A"'"},"toolb":{"kind":"scan","image":"ghcr.io/tomhennen/wrangle/toolb@'"$DIGEST_A"'"}}}' \
        > "$CATALOG"
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [ "$(image_of toola)" = "ghcr.io/tomhennen/wrangle/toola@$DIGEST_B" ]
    [ "$(image_of toolb)" = "ghcr.io/tomhennen/wrangle/toolb@$DIGEST_A" ]
    [[ "$output" == *"could not resolve"* ]]
}

@test "bump_catalog_to_latest: malformed catalog is an error (exit 2)" {
    printf '{ not json\n' > "$CATALOG"
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not valid JSON"* ]]
}
