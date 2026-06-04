#!/usr/bin/env bats

# Real consumer-side VSA verification — runs the EXACT commands the build-type
# READMEs document, against REAL checked-in artifacts (a real keyless VSA +
# its provenance + the package blob, captured from a green integration run).
# This is the regression backstop: if a documented consumer command drifts to
# something that doesn't actually verify our keyless VSAs (as `slsa-verifier
# verify-vsa` silently did), this fails.
#
# Needs real cosign + ampel + Sigstore (Fulcio/Rekor) reachability, so it runs
# in the `integration (real binaries)` job, not the hermetic unit suite. A
# keyless VSA still verifies long after signing because Rekor's inclusion
# timestamp proves the cert was valid at signing time. skip_or_fail keeps
# sandboxed local dev from hard-failing while CI rejects a silent skip.

load "../lib/bats_helpers"

# The real artifact the VSA covers (captured values — do not edit without
# re-capturing the fixtures from a real run).
SUBJECT_DIGEST="sha256:cbdb02a9ff57b76d75a0d51986d394383d3da18d2a3467a26a9ba69a03419018"
RESOURCE_URI="pkg:npm/@tomhennen/wrangle-integration-fixture@0.0.2-integration.26922828083"
SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_npm\.yml@'
SIGNER_REPO="TomHennen/wrangle-test"
ISSUER="https://token.actions.githubusercontent.com"
VSA_PREDICATE="https://slsa.dev/verification_summary/v1"

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    FIX="$DIR/fixtures"
    REPO_ROOT="$(cd "$DIR/../.." && pwd)"
    POLICY="$REPO_ROOT/policies/wrangle-vsa-consumer-v1.hjson"
    VSA="$FIX/npm-vsa.intoto.jsonl"
    # The real package tarball the VSA's subject digest covers (cosign hashes it).
    BLOB="$FIX/npm-package.tgz"
    COSIGN_BIN="$(command -v cosign || echo "${WRANGLE_BIN_DIR:-/nonexistent}/cosign")"
    AMPEL_BIN="$(command -v ampel || echo "${WRANGLE_BIN_DIR:-/nonexistent}/ampel")"
    TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

# Sigstore must be reachable for keyless verification; fail-not-skip under CI.
require_sigstore() {
    curl -fsS -m 10 -o /dev/null https://rekor.sigstore.dev/api/v1/log 2>/dev/null \
        || skip_or_fail "rekor.sigstore.dev unreachable"
}

# --- Path A: cosign verify-blob-attestation (signature + identity) ---

@test "consumer A: cosign verify-blob-attestation verifies the VSA's signer + subject" {
    [[ -x "$COSIGN_BIN" ]] || skip_or_fail "real cosign not available"
    require_sigstore
    run "$COSIGN_BIN" verify-blob-attestation --bundle "$VSA" --new-bundle-format \
        --certificate-oidc-issuer "$ISSUER" \
        --certificate-identity-regexp "$SIGNER_REGEX" \
        --certificate-github-workflow-repository "$SIGNER_REPO" \
        --type "$VSA_PREDICATE" \
        "$BLOB"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Verified OK"* ]]
}

@test "consumer A: cosign rejects a wrong signer identity (fail-closed)" {
    [[ -x "$COSIGN_BIN" ]] || skip_or_fail "real cosign not available"
    require_sigstore
    run "$COSIGN_BIN" verify-blob-attestation --bundle "$VSA" --new-bundle-format \
        --certificate-oidc-issuer "$ISSUER" \
        --certificate-identity-regexp '^https://github\.com/attacker/repo/' \
        --type "$VSA_PREDICATE" \
        "$BLOB"
    [[ "$status" -ne 0 ]]
}

# Path A only checks signature/identity; the SLSA-recommended field check is a
# decode + assert over the predicate. This pins the documented jq shape.
@test "consumer A: predicate fields decode to PASSED / expected resourceUri / L3" {
    payload="$(jq -r '.dsseEnvelope.payload' "$VSA" | base64 -d)"
    [[ "$(jq -r '.predicate.verificationResult' <<<"$payload")" == "PASSED" ]]
    [[ "$(jq -r '.predicate.resourceUri' <<<"$payload")" == "$RESOURCE_URI" ]]
    jq -e '.predicate.verifiedLevels | index("SLSA_BUILD_LEVEL_3")' <<<"$payload" >/dev/null
}

# --- Path B: ampel verify against the wrangle-hosted consumer policy ---

@test "consumer B: ampel verify PASSES (signature + identity + fields, one command)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$SUBJECT_DIGEST" \
        --policy "$POLICY" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}

@test "consumer B: ampel verify FAILS on a wrong expected resourceUri" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$SUBJECT_DIGEST" \
        --policy "$POLICY" --attestation "$VSA" \
        --context "expectedResourceUri:pkg:npm/@attacker/evil@9.9.9"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"FAIL"* ]]
}

@test "consumer B: ampel verify FAILS when the signer identity doesn't match (fail-closed)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    # Same policy with an identity that can't match our VSA's signer.
    sed 's#build_and_publish_\[a-z\]+#NOT_a_wrangle_workflow#' "$POLICY" > "$TMP/bad-identity.hjson"
    run "$AMPEL_BIN" verify --subject "$SUBJECT_DIGEST" \
        --policy "$TMP/bad-identity.hjson" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI"
    [[ "$status" -ne 0 ]]
}
