#!/usr/bin/env bats

# Unit tests for tools/check_catalog_freshness.sh — the network freshness check.
# Digest resolution is curl-only, so a fake `curl` on PATH stands in for the GHCR
# registry API: it dispatches on the request URL and returns a fixture digest (or
# fails), exercising the real token + manifest parse without any live call.

DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/check_catalog_freshness.sh"
    CATALOG="$BATS_TEST_TMPDIR/catalog.json"
    BIN_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN_DIR"
    export WRANGLE_CATALOG="$CATALOG" PATH="$BIN_DIR:$PATH"
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }

    printf '%s\n' \
        '{"tools":{"osv":{"kind":"scan","image":"ghcr.io/tomhennen/wrangle/osv@'"$DIGEST_A"'","network":"egress"}}}' \
        > "$CATALOG"
}

# install_curl — a fake `curl` for the registry API. It dispatches on the request
# URL and reads $SHIM_DIGEST / $SHIM_TOKEN_FAIL from the environment at run time.
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

# install_curl_per_image — a fake `curl` that behaves per image: toola resolves a
# drifted digest, toolb's registry lookup fails.
install_curl_per_image() {
    cat >"$BIN_DIR/curl" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *toolb*) exit 22 ;;                                 # toolb: registry unreachable
    *token\?*) printf '{"token":"t"}\n'; exit 0 ;;
    *toola/manifests*) printf 'HTTP/2 200\r\ndocker-content-digest: $DIGEST_B\r\n\r\n'; exit 0 ;;
  esac
done
exit 0
SHIM
    chmod +x "$BIN_DIR/curl"
}

@test "check_catalog_freshness: in-sync digest passes (exit 0)" {
    install_curl
    SHIM_DIGEST="$DIGEST_A" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"match :latest"* ]]
}

@test "check_catalog_freshness: drifted digest fails with bump remediation (exit 1)" {
    install_curl
    SHIM_DIGEST="$DIGEST_B" run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"behind :latest"* ]]
    [[ "$output" == *"bump_catalog_digest.sh osv $DIGEST_B"* ]]
}

@test "check_catalog_freshness: a kind:attest image entry (the signing toolbox) is covered, not skipped" {
    # Regression for #689: the toolbox image the signing path depends on must be
    # freshness-checked like any curated image. The filter keys on the named
    # image, not kind — so a kind: attest entry drifts loudly, not
    # silently. (A stale, validly-attested toolbox digest is the one risk the
    # pull-time VSA gate cannot catch.)
    install_curl
    printf '%s\n' \
        '{"tools":{"attest-toolbox":{"kind":"attest","image":"ghcr.io/tomhennen/wrangle/attest-toolbox@'"$DIGEST_A"'","network":"egress","token":"sigstore"}}}' \
        > "$CATALOG"
    SHIM_DIGEST="$DIGEST_B" run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"behind :latest"* ]]
    [[ "$output" == *"attest-toolbox"* ]]
}

@test "check_catalog_freshness: registry unreachable is an env error (exit 2)" {
    install_curl
    SHIM_TOKEN_FAIL=1 run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not resolve"* ]]
}

@test "check_catalog_freshness: malformed digest header is an env error (exit 2)" {
    install_curl
    SHIM_DIGEST="not-a-digest" run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not resolve"* ]]
}

# Security-critical precedence: a confirmed drift must not be masked by another
# tool's backend error.
@test "check_catalog_freshness: drift wins over a second tool's backend error (exit 1)" {
    install_curl_per_image
    printf '%s\n' \
        '{"tools":{"toola":{"kind":"scan","image":"ghcr.io/tomhennen/wrangle/toola@'"$DIGEST_A"'"},"toolb":{"kind":"scan","image":"ghcr.io/tomhennen/wrangle/toolb@'"$DIGEST_A"'"}}}' \
        > "$CATALOG"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"behind :latest"* ]]
    [[ "$output" == *"could not resolve"* ]]
}

@test "check_catalog_freshness: non-curated entry is skipped" {
    # Token-fail shim: if a non-curated entry were resolved, this would exit 2.
    install_curl
    printf '%s\n' \
        '{"tools":{"adopter":{"kind":"scan","image":"registry.example.com/x/y@'"$DIGEST_A"'"}}}' \
        > "$CATALOG"
    SHIM_TOKEN_FAIL=1 run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 curated image"* ]]
}

@test "check_catalog_freshness: malformed catalog is an env error (exit 2)" {
    printf '{ not json\n' > "$CATALOG"
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not valid JSON"* ]]
}
