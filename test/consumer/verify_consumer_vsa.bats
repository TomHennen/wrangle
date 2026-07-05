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
    # A real go release bundle carrying the FULL signed-metadata set the other
    # fixtures lack: provenance + signed SBOM + signed osv/zizmor/wrangle-lint
    # scan/v1 + VSA, one signed statement per line. Captured from a release-tag
    # (@refs/tags/v0.3.0) build, so it verifies under the strict $POLICY.
    META_BUNDLE="$FIX/go-signed-metadata.intoto.jsonl"
    META_BLOB="$FIX/go-signed-metadata-package.tar.gz"
    META_URI="pkg:golang/github.com/TomHennen/wrangle-agent-playground@v0.2.0"
    META_REPO="TomHennen/wrangle-agent-playground"
    SBOM_PREDICATE="https://spdx.dev/Document"
    SCAN_PREDICATE="https://github.com/TomHennen/wrangle/attestation/scan/v1"
    GO_SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_go\.yml@'
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

# verify_vsa.sh runs ampel in the toolbox image; the stub docker execs the
# in-container command on the host, so the symlinked real ampel verifies the real
# fixtures while the image VSA gate is faked.
gate_toolbox_transparent() {
    local stub="$TMP/toolbox-bin"
    mkdir -p "$stub"
    ln -sf "$AMPEL_BIN" "$stub/ampel"
    wrangle_stub_toolbox_transparent "$stub"
}

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
    gate_toolbox_transparent
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
    gate_toolbox_transparent
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
    gate_toolbox_transparent
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
    gate_toolbox_transparent
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
    gate_toolbox_transparent
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$RESOURCE_URI" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}

# --- multi-line bundle: per-subject self-selection + missing-subject fail-close ---
# wrangle ships one <artifact>.intoto.jsonl per released artifact; verify-vsa
# concatenates every bundle it finds into one JSONL stream. The gate no longer
# checks per-file existence; it relies on ampel self-selecting the matching
# subject's VSA from that whole stream. These build a GENUINE two-statement
# bundle (npm VSA + python VSA, one JSON object per line) from the real fixtures
# and prove the self-selection + fail-closed contract against real ampel — the
# publish gate's load-bearing guarantee.

# Concatenate the npm and python VSA fixtures into a real multi-line bundle, each
# flattened to one line. ampel reads it via the jsonl: collector.
_make_multiline_bundle() {
    jq -c . "$VSA" > "$1"
    jq -c . "$PY_VSA" >> "$1"
}

@test "consumer multi-line: ampel self-selects the matching subject's VSA from a 2-statement bundle" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    _make_multiline_bundle "$TMP/bundle.jsonl"
    # The npm blob's subject is line 1; the python wheel's is line 2. Both must
    # PASS against the SAME bundle — ampel picks the right VSA per subject.
    run "$AMPEL_BIN" verify --subject "$BLOB" \
        --policy "$POLICY" --collector "jsonl:$TMP/bundle.jsonl" \
        --context "expectedResourceUri:$RESOURCE_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
    run "$AMPEL_BIN" verify --subject "$PY_BLOB" \
        --policy "$POLICY" --collector "jsonl:$TMP/bundle.jsonl" \
        --context "expectedResourceUri:$PY_RESOURCE_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}

@test "consumer multi-line: a file whose subject is ABSENT from the bundle FAILS closed" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    _make_multiline_bundle "$TMP/bundle.jsonl"
    # The keystone of the per-subject-VSA design: dropping the per-file existence
    # check is only safe if ampel fails closed when no VSA in the bundle covers
    # the subject. These bytes match no subject in the bundle — must not pass.
    printf 'no VSA covers these bytes' > "$TMP/absent.tgz"
    run "$AMPEL_BIN" verify --subject "$TMP/absent.tgz" \
        --policy "$POLICY" --collector "jsonl:$TMP/bundle.jsonl" \
        --context "expectedResourceUri:$RESOURCE_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -ne 0 ]]
}

@test "consumer multi-line: a bundle with only the WRONG subject's VSA does not satisfy the target file" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    # The npm blob is verified against a bundle holding ONLY the python wheel's
    # VSA. ampel must not cross-apply the wrong subject's VSA.
    jq -c . "$PY_VSA" > "$TMP/py-only.jsonl"
    run "$AMPEL_BIN" verify --subject "$BLOB" \
        --policy "$POLICY" --collector "jsonl:$TMP/py-only.jsonl" \
        --context "expectedResourceUri:$RESOURCE_URI" \
        --context "sourceRepo:https://github.com/$SIGNER_REPO"
    [[ "$status" -ne 0 ]]
}

# The gate script (actions/verify-vsa) drives the real per-artifact bundles
# exactly as the action does: separate <artifact>.intoto.jsonl files in VSA_DIR
# that verify_vsa.sh concatenates, ampel self-selecting per dist file. Proves
# the production wrapper — not just raw ampel — verifies across per-artifact
# bundles.
@test "verify-vsa: gate verifies across per-artifact bundles, self-selecting per dist file" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    cp "$BLOB" "$TMP/dist/npm-package.tgz"
    # One bundle per artifact, the production layout; the gate concatenates them.
    jq -c . "$VSA" > "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    jq -c . "$PY_VSA" > "$TMP/vsas/py-package.whl.intoto.jsonl"
    gate_toolbox_transparent
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$RESOURCE_URI" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"verified against PASSED VSAs"* ]]
}

# The gate's fail-closed counterpart: the dist file is present, the per-artifact
# bundles are real and signed, but they cover OTHER subjects — never this file.
# Dropping the per-file existence check must not let an uncovered file publish.
@test "verify-vsa: gate FAILS closed when no per-artifact bundle covers the dist file" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    mkdir -p "$TMP/dist" "$TMP/vsas"
    printf 'bytes no VSA covers' > "$TMP/dist/uncovered.tgz"
    jq -c . "$VSA" > "$TMP/vsas/npm-package.tgz.intoto.jsonl"
    jq -c . "$PY_VSA" > "$TMP/vsas/py-package.whl.intoto.jsonl"
    gate_toolbox_transparent
        ARTIFACT_PATH="$TMP/dist" RESOURCE_URI="$RESOURCE_URI" REPO="$SIGNER_REPO" VSA_DIR="$TMP/vsas" \
        run "$REPO_ROOT/actions/verify-vsa/verify_vsa.sh"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"ampel rejected"* ]]
}

# --- #562: signed-metadata bundle (SBOM + scan/v1) regression ----------------
# The other consumer fixtures carry only VSA + provenance, so an attest-signing
# regression that dropped — or stopped signing — the SBOM/scan metadata (#550
# moved metadata signing into attest) would go unnoticed here. This bundle is a
# real release capture with the FULL signed set; these tests fail closed if a
# future regression strips a statement, leaves it unsigned, or breaks the strict
# consumer verify over the whole bundle.

# Emit each bundle line whose statement predicateType matches $1, one per line.
_lines_with_predicate() {
    local pt
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        pt="$(jq -r '.dsseEnvelope.payload' <<<"$line" | base64 -d | jq -r '.predicateType')"
        if [[ "$pt" == "$1" ]]; then printf '%s\n' "$line"; fi
    done < "$META_BUNDLE"
    return 0
}

@test "consumer #562: bundle carries a signed SBOM cosign verifies against the go signer" {
    [[ -x "$COSIGN_BIN" ]] || skip_or_fail "real cosign not available"
    require_sigstore
    local sbom="$TMP/sbom.jsonl"
    _lines_with_predicate "$SBOM_PREDICATE" > "$sbom"
    # Exactly one SBOM statement, and it must be signed by wrangle's go workflow.
    [[ "$(wc -l <"$sbom")" -eq 1 ]]
    run "$COSIGN_BIN" verify-blob-attestation --bundle "$sbom" --new-bundle-format \
        --certificate-oidc-issuer "$ISSUER" \
        --certificate-identity-regexp "$GO_SIGNER_REGEX" \
        --certificate-github-workflow-repository "$META_REPO" \
        --type "$SBOM_PREDICATE" \
        "$META_BLOB"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Verified OK"* ]]
}

@test "consumer #562: bundle carries signed osv/zizmor/wrangle-lint scan/v1, each cosign-verifies" {
    [[ -x "$COSIGN_BIN" ]] || skip_or_fail "real cosign not available"
    require_sigstore
    local scans="$TMP/scans.jsonl"
    _lines_with_predicate "$SCAN_PREDICATE" > "$scans"
    # All three default-go-v1 scan tools are present as distinct scan/v1 statements.
    run bash -c "while IFS= read -r l; do jq -r '.dsseEnvelope.payload' <<<\"\$l\" | base64 -d | jq -r '.predicate.tool.name'; done < '$scans' | sort -u"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"osv-scanner"* ]]
    [[ "$output" == *"zizmor"* ]]
    [[ "$output" == *"wrangle-lint"* ]]
    # Each scan/v1 statement is signed by wrangle's go workflow (one cosign verify
    # per line, so an unsigned statement fails closed).
    while IFS= read -r line; do
        printf '%s\n' "$line" > "$TMP/one-scan.jsonl"
        run "$COSIGN_BIN" verify-blob-attestation --bundle "$TMP/one-scan.jsonl" \
            --new-bundle-format \
            --certificate-oidc-issuer "$ISSUER" \
            --certificate-identity-regexp "$GO_SIGNER_REGEX" \
            --certificate-github-workflow-repository "$META_REPO" \
            --type "$SCAN_PREDICATE" \
            "$META_BLOB"
        [[ "$status" -eq 0 ]]
        [[ "$output" == *"Verified OK"* ]]
    done < "$scans"
}

@test "consumer #562: strict wrangle-vsa-consumer-v1 still verifies the full signed-metadata bundle" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$META_BLOB" \
        --policy "$POLICY" --collector "jsonl:$META_BUNDLE" \
        --context "expectedResourceUri:$META_URI" \
        --context "sourceRepo:https://github.com/$META_REPO"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}
