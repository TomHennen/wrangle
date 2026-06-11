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

# Captured from a real run — do not edit without re-capturing the fixtures.
# No hardcoded npm digest: ampel and cosign compute it from the package blob,
# exactly as a consumer does; only the *expected* resourceUri/identity are pinned.
RESOURCE_URI="pkg:npm/@tomhennen/wrangle-integration-fixture@0.0.2-integration.26922828083"
SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_npm\.yml@'
SIGNER_REPO="TomHennen/wrangle-test"
ISSUER="https://token.actions.githubusercontent.com"
VSA_PREDICATE="https://slsa.dev/verification_summary/v1"
# A real PYTHON VSA (wheel subject) from run 26991037293 — same cosign
# verify-blob-attestation shape as npm, but a distinct signer workflow and a
# pkg:generic resourceUri, so it can drift independently of the npm path.
PY_RESOURCE_URI="pkg:generic/wrangle_test_fixture@0.0.1.dev26991037293"
PY_SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_python\.yml@'
# A real CONTAINER VSA (digest subject) from the same run — covers the
# digest-native ampel path (no file blob) that npm/go don't exercise.
CONTAINER_DIGEST="sha256:9984046b479c57d037f15ddf10bb1266adb2b7707f810c47b53c97af3a5488ad"
CONTAINER_URI="ghcr.io/tomhennen/wrangle-test-staging@sha256:9984046b479c57d037f15ddf10bb1266adb2b7707f810c47b53c97af3a5488ad"

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    FIX="$DIR/fixtures"
    REPO_ROOT="$(cd "$DIR/../.." && pwd)"
    POLICY="$REPO_ROOT/policies/wrangle-vsa-consumer-v1.hjson"
    VSA="$FIX/npm-vsa.intoto.jsonl"
    # The real package tarball the VSA's subject digest covers (cosign hashes it).
    BLOB="$FIX/npm-package.tgz"
    PY_VSA="$FIX/python-vsa.intoto.jsonl"
    PY_BLOB="$FIX/python-package.whl"
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

# --- Path A (python): the python README's verify-blob-attestation command ---
# Same shape as npm, exercised against a real python wheel + its VSA so the
# python README's literals (signer workflow, pkg:generic resourceUri) can't
# drift unnoticed.

@test "consumer A (python): cosign verify-blob-attestation verifies the wheel's signer + subject" {
    [[ -x "$COSIGN_BIN" ]] || skip_or_fail "real cosign not available"
    require_sigstore
    run "$COSIGN_BIN" verify-blob-attestation --bundle "$PY_VSA" --new-bundle-format \
        --certificate-oidc-issuer "$ISSUER" \
        --certificate-identity-regexp "$PY_SIGNER_REGEX" \
        --certificate-github-workflow-repository "$SIGNER_REPO" \
        --type "$VSA_PREDICATE" \
        "$PY_BLOB"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Verified OK"* ]]
}

@test "consumer A (python): cosign rejects a wrong signer identity (fail-closed)" {
    [[ -x "$COSIGN_BIN" ]] || skip_or_fail "real cosign not available"
    require_sigstore
    run "$COSIGN_BIN" verify-blob-attestation --bundle "$PY_VSA" --new-bundle-format \
        --certificate-oidc-issuer "$ISSUER" \
        --certificate-identity-regexp '^https://github\.com/attacker/repo/' \
        --type "$VSA_PREDICATE" \
        "$PY_BLOB"
    [[ "$status" -ne 0 ]]
}

@test "consumer A (python): predicate fields decode to PASSED / pkg:generic resourceUri / L3" {
    payload="$(jq -r '.dsseEnvelope.payload' "$PY_VSA" | base64 -d)"
    [[ "$(jq -r '.predicate.verificationResult' <<<"$payload")" == "PASSED" ]]
    [[ "$(jq -r '.predicate.resourceUri' <<<"$payload")" == "$PY_RESOURCE_URI" ]]
    jq -e '.predicate.verifiedLevels | index("SLSA_BUILD_LEVEL_3")' <<<"$payload" >/dev/null
}

# --- Path B: ampel verify against the wrangle-hosted consumer policy ---
# Needs ampel >= v1.3.0: the policy's sourceRepositoryUriMatch binds the
# signing cert's source-repository extension (the origin repo) to the
# consumer-supplied sourceRepo context; older ampel can't parse the policy.

@test "consumer B: ampel verify PASSES (signature + identity + origin repo + fields, one command)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$BLOB" \
        --policy "$POLICY" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}

@test "consumer B: ampel verify FAILS on a wrong expected resourceUri" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$BLOB" \
        --policy "$POLICY" --attestation "$VSA" \
        --context "expectedResourceUri:pkg:npm/@attacker/evil@9.9.9" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"FAIL"* ]]
}

@test "consumer B: ampel verify FAILS on a wrong origin repo (fail-closed repo binding)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    # A wrangle-signed VSA built in a different repo must be rejected even
    # though the signer identity (wrangle's reusable workflow) matches.
    run "$AMPEL_BIN" verify --subject "$BLOB" \
        --policy "$POLICY" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI" \
        --context "sourceRepo:https://github.com/attacker/evil-repo"
    [[ "$status" -ne 0 ]]
}

@test "consumer B: ampel verify ERRORS when sourceRepo is not supplied (no silent skip)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$BLOB" \
        --policy "$POLICY" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI"
    [[ "$status" -ne 0 ]]
}

@test "consumer B (container): ampel verify a real container VSA by digest subject" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$CONTAINER_DIGEST" \
        --policy "$POLICY" --attestation "$FIX/container-vsa.intoto.jsonl" \
        --context "expectedResourceUri:$CONTAINER_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}

@test "consumer B: ampel verify FAILS when the signer identity doesn't match (fail-closed)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    # Same policy with an identity that can't match our VSA's signer.
    sed 's#build_and_publish_\[a-z\]+#NOT_a_wrangle_workflow#' "$POLICY" > "$TMP/bad-identity.hjson"
    run "$AMPEL_BIN" verify --subject "$BLOB" \
        --policy "$TMP/bad-identity.hjson" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -ne 0 ]]
}

# --- adopter-side publish gate (actions/verify-vsa) ---
# The gate script evaluates the wrangle-vsa-gate-v1 PolicySet with ampel;
# running it against the same real fixture proves the script's ampel
# invocation and policy wiring work on genuine bnd-emitted bundles, not just
# the unit suite's shim.

@test "verify-vsa: gate script verifies the real npm fixture end-to-end" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    cp "$VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        ARTIFACT_PATH="$TMP/dist" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" SIGNER_WORKFLOW="" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1 file(s) verified against PASSED VSAs"* ]]
}

@test "verify-vsa: gate script narrows to the npm signer workflow and still verifies" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    cp "$VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        ARTIFACT_PATH="$TMP/dist" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        SIGNER_WORKFLOW="TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1 file(s) verified against PASSED VSAs"* ]]
}

@test "verify-vsa: gate script rejects a mismatched signer workflow (fail-closed)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    cp "$VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    # The npm fixture's VSA was signed by the npm workflow; narrowing the
    # gate to the python workflow must reject it.
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        ARTIFACT_PATH="$TMP/dist" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        SIGNER_WORKFLOW="TomHennen/wrangle/.github/workflows/build_and_publish_python.yml" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}

@test "verify-vsa: gate script rejects the fixture under a wrong origin repo (fail-closed)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    cp "$VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        ARTIFACT_PATH="$TMP/dist" REPO="attacker/repo" VSA_DIR="$TMP/vsas" SIGNER_WORKFLOW="" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}

# The documented install path for the gate's ampel: provenance-verified
# release binary. Needs real cosign + the GitHub release CDN.
@test "verify-vsa: install_ampel.sh installs a provenance-verified ampel" {
    [[ -x "$COSIGN_BIN" ]] || skip_or_fail "real cosign not available"
    require_sigstore
    PATH="$(dirname "$COSIGN_BIN"):$PATH" WRANGLE_BIN_DIR="$TMP/bin" \
        run "$REPO_ROOT/actions/verify-vsa/install_ampel.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"provenance verified"* ]]
    run "$TMP/bin/ampel" version
    [[ "$output" == *"GitVersion"* ]]
}
