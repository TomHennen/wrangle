#!/usr/bin/env bats

# Real consumer-side VSA verification — runs the EXACT commands the consumer
# docs document (build-type READMEs + docs/verifying_artifacts.md), against
# REAL checked-in artifacts (a real keyless VSA + the package blob, captured
# from a green integration run).
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

# Captured from a curated v0.2.2 showcase run — do not edit without re-capturing
# the fixtures. The signer identity is now a release tag (@refs/tags/v0.2.2), so
# the tests verify against the STRICT shipped policy that adopters use. The one
# exception is npm-vsa-nontag, an old SHA-identity capture kept to prove the
# strict policy and gate reject a non-release VSA.
# No hardcoded npm digest: ampel and cosign compute it from the package blob,
# exactly as a consumer does; only the *expected* resourceUri/identity are pinned.
RESOURCE_URI="pkg:npm/@tomhennen/wrangle-integration-fixture@0.0.1-dev.27500274491"
SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_npm\.yml@'
SIGNER_REPO="TomHennen/wrangle-test"
ISSUER="https://token.actions.githubusercontent.com"
VSA_PREDICATE="https://slsa.dev/verification_summary/v1"
# A real PYTHON VSA (wheel subject) from the v0.2.2 curated showcase run — same
# cosign verify-blob-attestation shape as npm, but a distinct signer workflow.
PY_RESOURCE_URI="pkg:pypi/wrangle-test-fixture@0.0.1.dev27500274491"
PY_SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_python\.yml@'
# A real CONTAINER VSA (digest subject) from the same run — covers the
# digest-native ampel path (no file blob) that npm/go don't exercise.
CONTAINER_DIGEST="sha256:9d95b102a0dfff741005a14bc15b92b640a9e6feb3f1f04de0298dbbcfa5340c"
CONTAINER_URI="ghcr.io/tomhennen/wrangle-test-showcase@sha256:9d95b102a0dfff741005a14bc15b92b640a9e6feb3f1f04de0298dbbcfa5340c"

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
    # An old SHA-identity npm capture (signer ref is a SHA, not a release tag),
    # kept to drive the rejection / non-strict cases.
    NONTAG_VSA="$FIX/npm-vsa-nontag.intoto.jsonl"
    NONTAG_BLOB="$FIX/npm-package-nontag.tgz"
    NONTAG_URI="pkg:npm/@tomhennen/wrangle-integration-fixture@0.0.2-integration.26922828083"
    COSIGN_BIN="$(command -v cosign || echo "${WRANGLE_BIN_DIR:-/nonexistent}/cosign")"
    AMPEL_BIN="$(command -v ampel || echo "${WRANGLE_BIN_DIR:-/nonexistent}/ampel")"
    # The shipped strict policy requires a release-tag signer identity
    # (@refs/tags/v…). The main fixtures are release-tag-signed, so the tests run
    # against the strict $POLICY — the same policy adopters use. One test sets
    # WRANGLE_VSA_NON_STRICT=1 to exercise the ref-relaxed path the gate falls
    # back to for wrangle's own non-release dogfooding.
    TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

# Sigstore reachability decides the local skip only. In CI the verification
# command itself is the arbiter — a one-shot probe blip must not fail a job
# the real tool (with its own retries and TUF cache) would pass.
require_sigstore() {
    if in_ci; then return 0; fi
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
# python README's signer-workflow literal can't drift unnoticed.

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

@test "consumer A (python): predicate fields decode to PASSED / resourceUri / L3" {
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

# The keystone bind: the VSA must cover THESE bytes. Every other Path-B case
# varies a context or the signer identity; this one holds the real VSA, repo,
# and resourceUri valid and varies only the *subject bytes*. A pass here would
# mean "a signed VSA for the real package verifies a different blob" — i.e. the
# publish gate would green-light substituted bytes that never passed policy.
@test "consumer B: ampel verify FAILS on tampered subject bytes (valid VSA, wrong content)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    cp "$BLOB" "$TMP/tampered.tgz"
    printf 'tamper' >> "$TMP/tampered.tgz"   # one extra byte -> different sha256
    run "$AMPEL_BIN" verify --subject "$TMP/tampered.tgz" \
        --policy "$POLICY" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -ne 0 ]]
}

# The tightening that makes the consumer guarantee real: the SHIPPED strict
# policy requires a release-tag signer identity (@refs/tags/v…), so a VSA signed
# when the adopter pinned wrangle by SHA (identity @<sha>) is rejected. The
# nontag fixture is exactly that case (a PR-head SHA run), verified here against
# the strict policy — not the non-strict variant the tenet tests above use.
@test "consumer B: the shipped policy REJECTS a SHA-pinned (non-tag) signer identity" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$NONTAG_BLOB" \
        --policy "$POLICY" --attestation "$NONTAG_VSA" \
        --context "expectedResourceUri:$NONTAG_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -ne 0 ]]
}

# --- adopter-side publish gate (actions/verify-vsa) ---
# The gate runs the consumer PolicySet with ampel. With the default (strict)
# policy it requires a release-tag signer identity. The main fixtures are
# release-tag-signed, so the gate admits them under the strict default — exactly
# what an adopter sees when they pin wrangle by release tag. The nontag fixture
# (a SHA-identity capture) is rejected by that same default, and
# WRANGLE_VSA_NON_STRICT=1 swaps in the ref-relaxed policy so it too is admitted.
@test "verify-vsa: gate script verifies a release-tag VSA under the strict default" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    cp "$VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$RESOURCE_URI" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"verified against PASSED VSAs"* ]]
}

# The flip side of the strict default: a SHA-identity (non-release) VSA is
# rejected by the shipped gate, even with the real bytes, repo, and resourceUri.
@test "verify-vsa: gate script rejects a SHA-pinned (non-tag) VSA under the strict default" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$NONTAG_BLOB" "$TMP/dist/npm-package.tgz"
    cp "$NONTAG_VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$NONTAG_URI" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}

# Internal dogfood switch: WRANGLE_VSA_NON_STRICT=1 selects the non-strict
# consumer policy (any wrangle build ref, not just release tags), so the
# SHA-pinned fixture the strict gate rejects above is admitted. Holds every
# other binding (repo, resourceUri, subject bytes) at its real value — only the
# ref anchor differs between the two policies.
@test "verify-vsa: WRANGLE_VSA_NON_STRICT=1 ADMITS the SHA-pinned VSA the strict gate rejects" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$NONTAG_BLOB" "$TMP/dist/npm-package.tgz"
    cp "$NONTAG_VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        WRANGLE_VSA_NON_STRICT=1 \
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$NONTAG_URI" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"verified against PASSED VSAs"* ]]
}

# Gate-level repo binding: the wrapper threads REPO into the policy's
# sourceRepo context, so a VSA whose signing cert names a different origin repo
# must be rejected even though the signer identity passes. Same admit setup as
# above (strict default), only REPO is wrong.
@test "verify-vsa: gate FAILS on a wrong origin repo (fail-closed repo binding)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    cp "$VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$RESOURCE_URI" REPO="attacker/evil-repo" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}

# Gate-level tamper bind: the wrapper verifies the bytes on disk against the
# VSA's subject digest. With the strict default policy and the correct repo, a
# dist file mutated by one byte (so its sha256 no longer matches the VSA) must
# still be rejected — the publish gate refuses substituted bytes.
@test "verify-vsa: gate FAILS on tampered subject bytes (valid VSA, wrong content)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    printf 'tamper' >> "$TMP/dist/npm-package.tgz"   # one extra byte -> different sha256
    cp "$VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$RESOURCE_URI" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}
