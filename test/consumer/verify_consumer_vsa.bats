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

# Captured from a real run — do not edit without re-capturing the fixtures.
# No hardcoded npm digest: ampel and cosign compute it from the package blob,
# exactly as a consumer does; only the *expected* resourceUri/identity are pinned.
RESOURCE_URI="pkg:npm/@tomhennen/wrangle-integration-fixture@0.0.2-integration.26922828083"
SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_npm\.yml@'
SIGNER_REPO="TomHennen/wrangle-test"
ISSUER="https://token.actions.githubusercontent.com"
VSA_PREDICATE="https://slsa.dev/verification_summary/v1"
# A real PYTHON VSA (wheel subject) from run 26991037293 — same cosign
# verify-blob-attestation shape as npm, but a distinct signer workflow. This
# capture predates the pkg:pypi migration (#373), and a keyless-signed VSA
# can't be re-resourced without re-signing, so its resourceUri stays the old
# pkg:generic form; releases now emit pkg:pypi (PEP 503-normalized). Re-capture
# from a post-migration release to flip this.
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
    # The shipped strict policy requires a release-tag signer identity
    # (@refs/tags/v…). The captured fixtures are from PR-head SHA runs, so their
    # signer ref is a SHA — tenet and repo-binding tests run against the
    # committed non-strict policy, which relaxes only the ref anchor to @.+ (the
    # variant wrangle uses for its own @main dogfooding). A dedicated test below
    # proves the strict policy still rejects the SHA identity.
    POLICY_NONSTRICT="$REPO_ROOT/policies/wrangle-vsa-consumer-nonstrict-v1.hjson"
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
# python README's signer-workflow literal can't drift unnoticed. The
# resourceUri here is the fixture's pre-#373 pkg:generic value (see above),
# not the pkg:pypi form releases now emit.

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
        --policy "$POLICY_NONSTRICT" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}

@test "consumer B: ampel verify FAILS on a wrong expected resourceUri" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$BLOB" \
        --policy "$POLICY_NONSTRICT" --attestation "$VSA" \
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
        --policy "$POLICY_NONSTRICT" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI" \
        --context "sourceRepo:https://github.com/attacker/evil-repo"
    [[ "$status" -ne 0 ]]
}

@test "consumer B: ampel verify ERRORS when sourceRepo is not supplied (no silent skip)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$BLOB" \
        --policy "$POLICY_NONSTRICT" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI"
    [[ "$status" -ne 0 ]]
}

@test "consumer B (container): ampel verify a real container VSA by digest subject" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$CONTAINER_DIGEST" \
        --policy "$POLICY_NONSTRICT" --attestation "$FIX/container-vsa.intoto.jsonl" \
        --context "expectedResourceUri:$CONTAINER_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}

@test "consumer B: ampel verify FAILS when the signer identity doesn't match (fail-closed)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    # Same policy with an identity that can't match our VSA's signer.
    sed 's#build_and_publish_\[a-z\]+#NOT_a_wrangle_workflow#' "$POLICY_NONSTRICT" > "$TMP/bad-identity.hjson"
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
        --policy "$POLICY_NONSTRICT" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -ne 0 ]]
}

# The tightening that makes the consumer guarantee real: the SHIPPED strict
# policy requires a release-tag signer identity (@refs/tags/v…), so a VSA signed
# when the adopter pinned wrangle by SHA (identity @<sha>) is rejected. This
# fixture is exactly that case (a PR-head SHA run), verified here against the
# strict policy — not the non-strict variant the tenet tests above use.
@test "consumer B: the shipped policy REJECTS a SHA-pinned (non-tag) signer identity" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$BLOB" \
        --policy "$POLICY" --attestation "$VSA" \
        --context "expectedResourceUri:$RESOURCE_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -ne 0 ]]
}

# --- adopter-side publish gate (actions/verify-vsa) ---
# The gate runs the consumer PolicySet with ampel. With the default (strict)
# policy it requires a release-tag signer identity, and the only real bundles we
# have are from PR-head SHA runs — so the gate rejects them, which is exactly
# what an adopter sees if they SHA-pin wrangle. WRANGLE_VSA_NON_STRICT=1 swaps in
# the ref-relaxed policy so the same SHA fixture is admitted, letting the
# admit-path, repo-binding, and tamper checks run end-to-end through the wrapper.
@test "verify-vsa: gate script rejects a SHA-pinned (non-tag) VSA — tag-pinning enforced" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    cp "$VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$RESOURCE_URI" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}

# Internal dogfood switch: WRANGLE_VSA_NON_STRICT=1 selects the non-strict
# consumer policy (any wrangle build ref, not just release tags), so the SAME
# SHA-pinned fixture the strict gate rejects above is admitted. Holds every
# other binding (repo, resourceUri, subject bytes) at its real value — only the
# ref anchor differs between the two policies.
@test "verify-vsa: WRANGLE_VSA_NON_STRICT=1 ADMITS the SHA-pinned VSA the strict gate rejects" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    cp "$VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        WRANGLE_VSA_NON_STRICT=1 \
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$RESOURCE_URI" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"verified against PASSED VSAs"* ]]
}

# Gate-level repo binding: the wrapper threads REPO into the policy's
# sourceRepo context, so a VSA whose signing cert names a different origin repo
# must be rejected even with the admit-path policy. Same admit setup as above,
# only REPO is wrong.
@test "verify-vsa: gate FAILS on a wrong origin repo (fail-closed repo binding)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    cp "$VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        WRANGLE_VSA_NON_STRICT=1 \
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$RESOURCE_URI" REPO="attacker/evil-repo" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}

# Gate-level tamper bind: the wrapper verifies the bytes on disk against the
# VSA's subject digest. With the admit-path policy and the correct repo, a dist
# file mutated by one byte (so its sha256 no longer matches the VSA) must still
# be rejected — the publish gate refuses substituted bytes.
@test "verify-vsa: gate FAILS on tampered subject bytes (valid VSA, wrong content)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    printf 'tamper' >> "$TMP/dist/npm-package.tgz"   # one extra byte -> different sha256
    cp "$VSA" "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    PATH="$(dirname "$AMPEL_BIN"):$PATH" \
        WRANGLE_VSA_NON_STRICT=1 \
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$RESOURCE_URI" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}
