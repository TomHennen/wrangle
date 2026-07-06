#!/usr/bin/env bats

# End-to-end check that tools/verify_documented_recipes.sh — the extract-and-run
# recipe runner a showcase calls — actually verifies a real keyless VSA by
# executing the fenced blocks from docs/verifying_artifacts.md. Drives the
# checked-in npm fixture (a real release-tag-signed VSA + its package blob),
# through the file-artifact recipes (ampel jsonl collector, cosign + jq, the
# verifiedLevels read).
#
# Needs real cosign + ampel + Sigstore reachability and fetches the shipped
# consumer policy by locator, so it runs in the integration job, not the
# hermetic unit suite. skip_or_fail keeps sandboxed local dev from hard-failing
# while CI rejects a silent skip.

load "../lib/bats_helpers"

RESOURCE_URI="pkg:npm/@tomhennen/wrangle-integration-fixture@0.0.1-dev.27500274491"
SIGNER_REPO="TomHennen/wrangle-test"

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    FIX="$DIR/fixtures"
    REPO_ROOT="$(cd "$DIR/../.." && pwd)"
    SCRIPT="$REPO_ROOT/tools/verify_documented_recipes.sh"
    BLOB="$FIX/npm-package.tgz"
    BUNDLE="$FIX/npm-vsa.intoto.jsonl"
    AMPEL_BIN="$(command -v ampel || echo "${WRANGLE_BIN_DIR:-/nonexistent}/ampel")"
    COSIGN_BIN="$(command -v cosign || echo "${WRANGLE_BIN_DIR:-/nonexistent}/cosign")"
    TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

require_sigstore() {
    if in_ci; then return 0; fi
    curl -fsS -m 10 -o /dev/null https://rekor.sigstore.dev/api/v1/log 2>/dev/null \
        || skip_or_fail "rekor.sigstore.dev unreachable"
}

require_tools() {
    [[ -x "$AMPEL_BIN" && -x "$COSIGN_BIN" ]] || skip_or_fail "real ampel + cosign not available"
}

@test "runner verifies a real release-tag VSA through the documented file recipes" {
    require_tools
    require_sigstore
    PATH="$(dirname "$AMPEL_BIN"):$(dirname "$COSIGN_BIN"):$PATH" \
        run "$SCRIPT" --file "$BLOB" --bundle "$BUNDLE" \
        --resource-uri "$RESOURCE_URI" --repo "$SIGNER_REPO" --type npm
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"3 passed, 0 failed"* ]]
}

@test "runner FAILS closed on tampered artifact bytes (valid VSA, wrong content)" {
    require_tools
    require_sigstore
    cp "$BLOB" "$TMP/tampered.tgz"
    printf 'tamper' >> "$TMP/tampered.tgz"   # one extra byte -> different sha256
    # Tamper failure is deterministic, so retrying (and re-hitting Sigstore) is
    # pointless — fail fast.
    PATH="$(dirname "$AMPEL_BIN"):$(dirname "$COSIGN_BIN"):$PATH" \
        WRANGLE_RECIPE_RETRIES=1 \
        run "$SCRIPT" --file "$TMP/tampered.tgz" --bundle "$BUNDLE" \
        --resource-uri "$RESOURCE_URI" --repo "$SIGNER_REPO" --type npm
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL:"* ]]
}
