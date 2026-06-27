#!/usr/bin/env bats

# Unit tests for tools/check_catalog_freshness.sh — the network freshness check.
# This is wrangle's first network-dependent pin check, so the registry CLI is
# shimmed: a fake `crane` on PATH echoes a fixture digest (or fails). The script
# prefers crane when present, so the shim deterministically drives the resolve
# path without any real registry call.

load "lib/bats_helpers"

DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"

# The curl-fallback path is only reached when crane is absent (the script prefers
# crane). A real crane on a dev host would hit the live registry, so force the
# intent: skip locally / fail in CI (where crane is absent, so this is a no-op).
require_craneless() {
    if command -v crane >/dev/null 2>&1; then
        skip_or_fail "crane present; curl fallback not exercised"
    fi
}

setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/check_catalog_freshness.sh"
    CATALOG="$BATS_TEST_TMPDIR/catalog.json"
    BIN_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN_DIR"
    export WRANGLE_CATALOG="$CATALOG" PATH="$BIN_DIR:$PATH"
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }

    printf '%s\n' \
        '{"tools":{"osv":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/osv@'"$DIGEST_A"'","network":"egress"}}}' \
        > "$CATALOG"
}

# install_crane <mode> — a fake `crane` whose `digest` output/return is fixed.
# Heredoc is expanded at write time, so each mode bakes its constant in.
install_crane() {
    cat >"$BIN_DIR/crane" <<SHIM
#!/usr/bin/env bash
case "$1" in
    insync) printf '%s\n' "$DIGEST_A" ;;     # matches the catalog pin
    drift)  printf '%s\n' "$DIGEST_B" ;;     # newer :latest than the pin
    down)   exit 1 ;;                          # registry unreachable
esac
SHIM
    chmod +x "$BIN_DIR/crane"
}

# install_crane_per_image — a fake `crane` that behaves per image ($2 is
# <imagename>:latest): toola drifts, toolb's registry lookup fails.
install_crane_per_image() {
    cat >"$BIN_DIR/crane" <<SHIM
#!/usr/bin/env bash
case "\$2" in
    *toola*) printf '%s\n' "$DIGEST_B" ;;    # resolves != pinned DIGEST_A -> drift
    *toolb*) exit 1 ;;                          # backend unreachable
esac
SHIM
    chmod +x "$BIN_DIR/crane"
}

# install_curl — a fake `curl` exercising the craneless production fallback
# (_digest_via_curl). It dispatches on the request URL and reads $SHIM_DIGEST /
# $SHIM_TOKEN_FAIL from the environment at run time.
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

@test "check_catalog_freshness: in-sync digest passes (exit 0)" {
    install_crane insync
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"match :latest"* ]]
}

@test "check_catalog_freshness: drifted digest fails with bump remediation (exit 1)" {
    install_crane drift
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"behind :latest"* ]]
    [[ "$output" == *"bump_catalog_digest.sh osv $DIGEST_B"* ]]
}

@test "check_catalog_freshness: registry unreachable is an env error (exit 2)" {
    install_crane down
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not resolve"* ]]
}

@test "check_catalog_freshness: non-curated entry is skipped" {
    install_crane down
    printf '%s\n' \
        '{"tools":{"adopter":{"kind":"scan","delivery":"image","image":"registry.example.com/x/y@'"$DIGEST_A"'"}}}' \
        > "$CATALOG"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 curated image"* ]]
}

@test "check_catalog_freshness: malformed catalog is an env error (exit 2)" {
    install_crane insync
    printf '{ not json\n' > "$CATALOG"
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not valid JSON"* ]]
}

# Security-critical precedence: a confirmed drift must not be masked by another
# tool's backend error.
@test "check_catalog_freshness: drift wins over a second tool's backend error (exit 1)" {
    install_crane_per_image
    printf '%s\n' \
        '{"tools":{"toola":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/toola@'"$DIGEST_A"'"},"toolb":{"kind":"scan","delivery":"image","image":"ghcr.io/tomhennen/wrangle/toolb@'"$DIGEST_A"'"}}}' \
        > "$CATALOG"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"behind :latest"* ]]
    [[ "$output" == *"could not resolve"* ]]
}

# The craneless production path (weekly workflow + release gate run on a runner
# without crane), exercised via a curl shim.
@test "check_catalog_freshness: curl fallback in-sync passes (exit 0)" {
    require_craneless
    install_curl
    SHIM_DIGEST="$DIGEST_A" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"match :latest"* ]]
}

@test "check_catalog_freshness: curl fallback drift fails with remediation (exit 1)" {
    require_craneless
    install_curl
    SHIM_DIGEST="$DIGEST_B" run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bump_catalog_digest.sh osv $DIGEST_B"* ]]
}

@test "check_catalog_freshness: curl fallback token failure is an env error (exit 2)" {
    require_craneless
    install_curl
    SHIM_TOKEN_FAIL=1 SHIM_DIGEST="$DIGEST_A" run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not resolve"* ]]
}

@test "check_catalog_freshness: curl fallback malformed digest header is an env error (exit 2)" {
    require_craneless
    install_curl
    SHIM_DIGEST="not-a-digest" run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not resolve"* ]]
}
