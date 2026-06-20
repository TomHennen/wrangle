#!/usr/bin/env bats

# Real consumer-side PROVENANCE verification — verifies the checked-in v1 SLSA
# provenance bundles (one per artifact-producing build type) the way a consumer
# would, and asserts their contents match docs/REQUIREMENTS_MAPPING.md's
# per-field provenance claims. Each bundle is a REAL signed
# actions/attest-build-provenance capture pulled from the GitHub attestation
# store (see the fixture header below for the source run/digests), not a
# hand-edited statement.
#
# Two layers:
#   - signature/identity: cosign verify-blob-attestation (blob subjects) and
#     ampel against the SHIPPED per-type policy (digest subjects too), so a
#     captured bundle that stopped verifying — or whose builder/type/point drift
#     out of the per-type policy — fails here.
#   - per-field doc tie: decode the predicate and assert the REQUIREMENTS_MAPPING
#     cells (predicate type, buildType, per-type builder.id, externalParameters
#     keys, metadata presence, buildDefinition/runDetails presence). This turns
#     those MEETS cells from prose-backed to artifact-backed.
#
# The synthetic policies/testdata/good-*.bundle.jsonl stay the hermetic
# policy-logic drift detector; this is the real-capture layer alongside them.
#
# Needs real cosign + ampel + Sigstore (Fulcio/Rekor) reachability, so it runs
# in the `integration (real binaries)` job, not the hermetic unit suite. A
# keyless bundle still verifies long after signing because Rekor's inclusion
# timestamp proves the cert was valid at signing time. skip_or_fail keeps
# sandboxed local dev from hard-failing while CI rejects a silent skip.

load "../lib/bats_helpers"

# Captured from tomhennen/wrangle-test Showcase run 27876119112 (source tag
# v20260620-44a586d, commit c747e27c). To re-capture: for each artifact digest
# below, `gh api /repos/tomhennen/wrangle-test/attestations/sha256:<digest>` and
# keep the `.attestations[].bundle` whose predicateType is the SLSA provenance.
# The signer ref is @refs/heads/main (a showcase build), which the per-type
# provenance policies accept — they bind the workflow PATH, any ref.
PROVENANCE_PREDICATE="https://slsa.dev/provenance/v1"
BUILD_TYPE="https://actions.github.io/buildtypes/workflow/v1"
ISSUER="https://token.actions.githubusercontent.com"
SIGNER_REPO="TomHennen/wrangle-test"
BUILD_POINT="git+https://github.com/TomHennen/wrangle-test"
# The container subject is a digest, not a file (digest-native ampel path).
CONTAINER_DIGEST="sha256:d7563c55d1d6bd90a5fac9d8ef45b502bed50128f2b01aff419cc0525e0ca6de"

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    FIX="$DIR/fixtures"
    REPO_ROOT="$(cd "$DIR/../.." && pwd)"
    POLICY_DIR="$REPO_ROOT/policies"
    COSIGN_BIN="$(command -v cosign || echo "${WRANGLE_BIN_DIR:-/nonexistent}/cosign")"
    AMPEL_BIN="$(command -v ampel || echo "${WRANGLE_BIN_DIR:-/nonexistent}/ampel")"
}

# Sigstore reachability decides the local skip only. In CI the verification
# command itself is the arbiter — a one-shot probe blip must not fail a job
# the real tool (with its own retries and TUF cache) would pass.
require_sigstore() {
    if in_ci; then return 0; fi
    curl -fsS -m 10 -o /dev/null https://rekor.sigstore.dev/api/v1/log 2>/dev/null \
        || skip_or_fail "rekor.sigstore.dev unreachable"
}

# Decode a bundle's DSSE payload (the in-toto statement) to stdout.
_payload() { jq -r '.dsseEnvelope.payload' "$1" | base64 -d; }

# --- Layer 1: signature + identity (cosign), per blob build type -------------
# Same shape as the VSA test's Path A, but over the provenance predicate and the
# per-type signer workflow, so each build type's signer literal can't drift.

@test "provenance (npm): cosign verifies the package's signer + subject" {
    [[ -x "$COSIGN_BIN" ]] || skip_or_fail "real cosign not available"
    require_sigstore
    run "$COSIGN_BIN" verify-blob-attestation \
        --bundle "$FIX/npm-provenance.intoto.jsonl" --new-bundle-format \
        --certificate-oidc-issuer "$ISSUER" \
        --certificate-identity-regexp '^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_npm\.yml@' \
        --certificate-github-workflow-repository "$SIGNER_REPO" \
        --type "$PROVENANCE_PREDICATE" \
        "$FIX/npm-provenance-package.tgz"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Verified OK"* ]]
}

@test "provenance (go): cosign verifies the archive's signer + subject" {
    [[ -x "$COSIGN_BIN" ]] || skip_or_fail "real cosign not available"
    require_sigstore
    run "$COSIGN_BIN" verify-blob-attestation \
        --bundle "$FIX/go-provenance.intoto.jsonl" --new-bundle-format \
        --certificate-oidc-issuer "$ISSUER" \
        --certificate-identity-regexp '^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_go\.yml@' \
        --certificate-github-workflow-repository "$SIGNER_REPO" \
        --type "$PROVENANCE_PREDICATE" \
        "$FIX/go-provenance-package.tar.gz"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Verified OK"* ]]
}

@test "provenance (python): cosign verifies the wheel's signer + subject" {
    [[ -x "$COSIGN_BIN" ]] || skip_or_fail "real cosign not available"
    require_sigstore
    run "$COSIGN_BIN" verify-blob-attestation \
        --bundle "$FIX/python-provenance.intoto.jsonl" --new-bundle-format \
        --certificate-oidc-issuer "$ISSUER" \
        --certificate-identity-regexp '^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_python\.yml@' \
        --certificate-github-workflow-repository "$SIGNER_REPO" \
        --type "$PROVENANCE_PREDICATE" \
        "$FIX/python-provenance-package.whl"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Verified OK"* ]]
}

@test "provenance (npm): cosign rejects a wrong signer identity (fail-closed)" {
    [[ -x "$COSIGN_BIN" ]] || skip_or_fail "real cosign not available"
    require_sigstore
    run "$COSIGN_BIN" verify-blob-attestation \
        --bundle "$FIX/npm-provenance.intoto.jsonl" --new-bundle-format \
        --certificate-oidc-issuer "$ISSUER" \
        --certificate-identity-regexp '^https://github\.com/attacker/repo/' \
        --type "$PROVENANCE_PREDICATE" \
        "$FIX/npm-provenance-package.tgz"
    [[ "$status" -ne 0 ]]
}

# --- Layer 1: the SHIPPED per-type policy (ampel) ----------------------------
# The strongest tie: each real capture must PASS the exact
# wrangle-provenance-<type>-v1.hjson the verify: job runs in CI — keyless
# identity + builder.id + buildType + build-point, one command. The container is
# the digest-native path no blob build type exercises.

@test "provenance (npm): ampel PASSES the shipped wrangle-provenance-npm-v1 policy" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$FIX/npm-provenance-package.tgz" \
        --policy "$POLICY_DIR/wrangle-provenance-npm-v1.hjson" \
        --attestation "$FIX/npm-provenance.intoto.jsonl" \
        --context "buildPoint:$BUILD_POINT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}

@test "provenance (go): ampel PASSES the shipped wrangle-provenance-go-v1 policy" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$FIX/go-provenance-package.tar.gz" \
        --policy "$POLICY_DIR/wrangle-provenance-go-v1.hjson" \
        --attestation "$FIX/go-provenance.intoto.jsonl" \
        --context "buildPoint:$BUILD_POINT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}

@test "provenance (python): ampel PASSES the shipped wrangle-provenance-python-v1 policy" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$FIX/python-provenance-package.whl" \
        --policy "$POLICY_DIR/wrangle-provenance-python-v1.hjson" \
        --attestation "$FIX/python-provenance.intoto.jsonl" \
        --context "buildPoint:$BUILD_POINT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}

@test "provenance (container): ampel PASSES the shipped policy on the digest subject" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$CONTAINER_DIGEST" \
        --policy "$POLICY_DIR/wrangle-provenance-container-v1.hjson" \
        --attestation "$FIX/container-provenance.intoto.jsonl" \
        --context "buildPoint:$BUILD_POINT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}

@test "provenance (npm): ampel FAILS the shipped policy on a wrong build point (fail-closed)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$FIX/npm-provenance-package.tgz" \
        --policy "$POLICY_DIR/wrangle-provenance-npm-v1.hjson" \
        --attestation "$FIX/npm-provenance.intoto.jsonl" \
        --context "buildPoint:git+https://github.com/attacker/evil-repo"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"FAIL"* ]]
}

# A wrangle-signed provenance from build type X must not satisfy build type Y's
# policy: the per-type builder.id is the load-bearing bind. The npm capture has
# builder.id …/build_and_publish_npm.yml, so the go policy must reject it.
@test "provenance: the go policy REJECTS an npm-signed bundle (per-type builder.id bind)" {
    [[ -x "$AMPEL_BIN" ]] || skip_or_fail "real ampel not available"
    require_sigstore
    run "$AMPEL_BIN" verify --subject "$FIX/npm-provenance-package.tgz" \
        --policy "$POLICY_DIR/wrangle-provenance-go-v1.hjson" \
        --attestation "$FIX/npm-provenance.intoto.jsonl" \
        --context "buildPoint:$BUILD_POINT"
    [[ "$status" -ne 0 ]]
}

# --- Layer 2: per-field tie to docs/REQUIREMENTS_MAPPING.md ------------------
# Decode the predicate and assert the per-field provenance table's cells against
# the real capture, so a future attest-build-provenance shape change that voids a
# documented MEETS cell fails here. The per-type builder.id literals come from
# policies/wrangle-provenance-<type>-v1.hjson.

@test "doc-tie: every captured bundle is SLSA provenance v1 with the workflow buildType" {
    for t in npm go python container; do
        payload="$(_payload "$FIX/$t-provenance.intoto.jsonl")"
        [[ "$(jq -r '.predicateType' <<<"$payload")" == "$PROVENANCE_PREDICATE" ]]
        [[ "$(jq -r '.predicate.buildDefinition.buildType' <<<"$payload")" == "$BUILD_TYPE" ]]
    done
}

@test "doc-tie: builder.id is the per-type reusable workflow (different mode → different builder.id)" {
    for t in npm go python container; do
        payload="$(_payload "$FIX/$t-provenance.intoto.jsonl")"
        builder="$(jq -r '.predicate.runDetails.builder.id' <<<"$payload")"
        [[ "$builder" == "https://github.com/TomHennen/wrangle/.github/workflows/build_and_publish_${t}.yml@"* ]]
    done
}

@test "doc-tie: externalParameters is the complete control-plane workflow invocation (repo, ref, path)" {
    for t in npm go python container; do
        payload="$(_payload "$FIX/$t-provenance.intoto.jsonl")"
        # externalParameters carries exactly the workflow invocation, nothing else.
        [[ "$(jq -c '.predicate.buildDefinition.externalParameters | keys' <<<"$payload")" == '["workflow"]' ]]
        wf="$(jq -c '.predicate.buildDefinition.externalParameters.workflow | keys' <<<"$payload")"
        [[ "$wf" == '["path","ref","repository"]' ]]
    done
}

@test "doc-tie: buildDefinition, runDetails, and metadata.invocationId are present" {
    for t in npm go python container; do
        payload="$(_payload "$FIX/$t-provenance.intoto.jsonl")"
        jq -e '.predicate.buildDefinition' <<<"$payload" >/dev/null
        jq -e '.predicate.runDetails' <<<"$payload" >/dev/null
        # The table claims metadata.* "where present"; invocationId is what
        # attest-build-provenance emits (startedOn/finishedOn are not present).
        jq -e '.predicate.runDetails.metadata.invocationId' <<<"$payload" >/dev/null
    done
}

@test "doc-tie: resolvedDependencies is disclosed best-effort (the source repo + commit, not the full closure)" {
    for t in npm go python container; do
        payload="$(_payload "$FIX/$t-provenance.intoto.jsonl")"
        # Best-effort: the one resolved dependency is the source repo itself,
        # bound by gitCommit — not the transitive dependency closure.
        [[ "$(jq -r '.predicate.buildDefinition.resolvedDependencies | length' <<<"$payload")" -ge 1 ]]
        jq -e '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit' <<<"$payload" >/dev/null
    done
}
