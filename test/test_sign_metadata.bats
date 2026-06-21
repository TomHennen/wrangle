#!/usr/bin/env bats

# Tests for lib/sign_metadata.sh — the shared attest-job orchestration that signs
# the build metadata and assembles the per-artifact <artifact>.intoto.jsonl
# bundles (provenance seed + that subject's signed metadata) (#566).
#
# wrangle-attest runs for real where a built binary is present (it self-digests
# offline); bnd/cosign are stubbed (keyless --sign + store/OCI push need
# OIDC/network). The pure helpers (seed, bundle-name, cosign-download args) run
# with no real tools.
load "lib/bats_helpers"

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    LIB="$REPO_ROOT/lib/sign_metadata.sh"
    TEST_DIR="$(mktemp -d)"
    export REPO_ROOT LIB TEST_DIR
    export RUNNER_TEMP="$TEST_DIR"
    export WRANGLE_RETRY_DELAY=0
    # shellcheck source=../lib/sign_metadata.sh
    source "$LIB"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Emit a DSSE-enveloped JSONL line whose decoded payload carries $1 as its
# predicateType — the shape cosign download returns for an OCI referrer.
_dsse_line() {
    local payload
    payload="$(printf '{"predicateType":"%s","subject":[]}' "$1" | base64 | tr -d '\n')"
    printf '{"dsseEnvelope":{"payload":"%s"}}\n' "$payload"
}

# --- bundle naming ---

@test "sign_metadata: bundle name is the basename with the digest colon replaced" {
    [[ "$(wrangle_bundle_name "dist/app-1.2.3.tgz")" == "app-1.2.3.tgz.intoto.jsonl" ]]
    [[ "$(wrangle_bundle_name "sha256:abc")" == "sha256-abc.intoto.jsonl" ]]
}

# --- cosign download args ---

@test "sign_metadata: cosign download args fetch the image's attestation referrers" {
    local target="ghcr.io/o/r/img@sha256:abc"
    mapfile -t args < <(wrangle_cosign_download_args "$target")
    [[ "${args[0]}" == "download" ]]
    [[ "${args[1]}" == "attestation" ]]
    [[ "${args[-1]}" == "$target" ]]
}

@test "sign_metadata: cosign download arg vector names a real cosign subcommand" {
    local cosign; cosign="$(command -v cosign || echo "${WRANGLE_BIN_DIR:-/nonexistent}/cosign")"
    [[ -x "$cosign" ]] || skip_or_fail "real cosign not available"
    run "$cosign" download attestation --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"download attestation"* ]]
}

# --- provenance seed ---

@test "sign_metadata: seed copies BUNDLE_IN when no OCI target" {
    export BUNDLE_IN="$TEST_DIR/provenance.jsonl"
    printf 'PROVLINE\n' > "$BUNDLE_IN"
    export OCI_TARGET=""
    local seed="$TEST_DIR/seed.jsonl"
    wrangle_seed_bundle "$seed"
    [[ "$(cat "$seed")" == "PROVLINE" ]]
    [[ "$(cat "$BUNDLE_IN")" == "PROVLINE" ]]
}

@test "sign_metadata: seed fails closed when BUNDLE_IN is missing or empty" {
    export OCI_TARGET=""
    export BUNDLE_IN="$TEST_DIR/absent.jsonl"
    run wrangle_seed_bundle "$TEST_DIR/seed.jsonl"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"provenance seed"* ]]
}

@test "sign_metadata: seed fetches provenance via cosign download for an OCI target" {
    {
        printf '#!/bin/bash\n'
        printf '[[ "$1" == "download" && "$2" == "attestation" ]] || exit 1\n'
        printf 'cat %q\n' "$TEST_DIR/referrers.jsonl"
    } > "$TEST_DIR/cosign"
    chmod +x "$TEST_DIR/cosign"
    _dsse_line "https://slsa.dev/provenance/v1" > "$TEST_DIR/referrers.jsonl"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    local seed="$TEST_DIR/seed.jsonl"
    wrangle_seed_bundle "$seed"
    [[ "$(wc -l < "$seed")" -eq 1 ]]
    [[ "$(jq -r '.dsseEnvelope.payload | @base64d | fromjson | .predicateType' "$seed")" == "https://slsa.dev/provenance/v1" ]]
}

@test "sign_metadata: seed drops a prior VSA referrer so a re-run stays idempotent" {
    # cosign download returns ALL referrers; a prior run left a VSA on the digest.
    # Seeding must keep only the provenance so the rebuilt bundle never accumulates
    # the stale VSA.
    {
        printf '#!/bin/bash\n'
        printf '[[ "$1" == "download" && "$2" == "attestation" ]] || exit 1\n'
        printf 'cat %q\n' "$TEST_DIR/referrers.jsonl"
    } > "$TEST_DIR/cosign"
    chmod +x "$TEST_DIR/cosign"
    {
        _dsse_line "https://slsa.dev/provenance/v1"
        _dsse_line "https://slsa.dev/verification_summary/v1"
    } > "$TEST_DIR/referrers.jsonl"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    local seed="$TEST_DIR/seed.jsonl"
    wrangle_seed_bundle "$seed"
    [[ "$(wc -l < "$seed")" -eq 1 ]]
    [[ "$(jq -r '.dsseEnvelope.payload | @base64d | fromjson | .predicateType' "$seed")" == "https://slsa.dev/provenance/v1" ]]
}

@test "sign_metadata: seed fails closed when no provenance referrer is present" {
    {
        printf '#!/bin/bash\n'
        printf '[[ "$1" == "download" && "$2" == "attestation" ]] || exit 1\n'
        printf 'cat %q\n' "$TEST_DIR/referrers.jsonl"
    } > "$TEST_DIR/cosign"
    chmod +x "$TEST_DIR/cosign"
    _dsse_line "https://slsa.dev/verification_summary/v1" > "$TEST_DIR/referrers.jsonl"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    run wrangle_seed_bundle "$TEST_DIR/seed.jsonl"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no SLSA provenance referrer"* ]]
}

# --- assemble bundles ---

# Stub wrangle-attest to emit one signed-metadata DSSE line binding the subject's
# digest (it would otherwise need OIDC for --sign). bnd/cosign record their pushes.
_stub_attest_tools() {
    cat > "$TEST_DIR/wrangle-attest" <<'STUB'
#!/bin/bash
set -euo pipefail
subj=""; out=""
for a in "$@"; do case "$a" in
    --subject=*) subj="${a#--subject=}";;
    --artifact=*) subj="sha256:$(sha256sum "${a#--artifact=}" | cut -d' ' -f1)";;
    --out=*) out="${a#--out=}";;
esac; done
digest="${subj#*:}"
payload="$(printf '{"predicateType":"https://spdx.dev/Document","subject":[{"digest":{"sha256":"%s"}}]}' "$digest" | base64 | tr -d '\n')"
printf '{"dsseEnvelope":{"payload":"%s"}}\n' "$payload" > "$out"
STUB
    cat > "$TEST_DIR/bnd" <<STUB
#!/bin/bash
[[ "\$1" == "push" ]] && { cat "\$4" >> "$TEST_DIR/store-pushed"; exit 0; }
exit 0
STUB
    cat > "$TEST_DIR/cosign" <<STUB
#!/bin/bash
for a in "\$@"; do [[ "\${prev:-}" == "--attestation" ]] && cat "\$a" >> "$TEST_DIR/oci-pushed"; prev="\$a"; done
exit 0
STUB
    chmod +x "$TEST_DIR/wrangle-attest" "$TEST_DIR/bnd" "$TEST_DIR/cosign"
    export PATH="$TEST_DIR:$PATH"
    : > "$TEST_DIR/store-pushed"; : > "$TEST_DIR/oci-pushed"
}

@test "sign_metadata: assemble writes one bundle per subject (seed + signed metadata) and pushes to the store" {
    _stub_attest_tools
    local meta="$TEST_DIR/meta"; mkdir -p "$meta"
    printf '{"spdxVersion":"SPDX-2.3"}' > "$meta/sbom.spdx.json"
    printf '{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}' > "$meta/wrangle_attestation_metadata.json"
    mkdir -p "$TEST_DIR/dist"
    printf 'AAA\n' > "$TEST_DIR/dist/a.tgz"
    printf 'BBB\n' > "$TEST_DIR/dist/b.tgz"
    local ha hb
    ha="$(sha256sum "$TEST_DIR/dist/a.tgz" | cut -d' ' -f1)"
    hb="$(sha256sum "$TEST_DIR/dist/b.tgz" | cut -d' ' -f1)"
    export BUNDLE_IN="$TEST_DIR/provenance.jsonl"; printf '{"provenance":1}\n' > "$BUNDLE_IN"
    export OCI_TARGET=""
    export METADATA_ROOT="$meta"
    export SUBJECTS="$TEST_DIR/dist/a.tgz"$'\n'"$TEST_DIR/dist/b.tgz"
    export GITHUB_REPOSITORY="o/r"
    export BUNDLE_OUT="$TEST_DIR/bundles"

    wrangle_sign_and_assemble_bundles

    local a="$BUNDLE_OUT/a.tgz.intoto.jsonl" b="$BUNDLE_OUT/b.tgz.intoto.jsonl"
    [[ -f "$a" && -f "$b" ]]
    # Each bundle = the shared provenance seed + that subject's signed metadata.
    [[ "$(head -n1 "$a")" == '{"provenance":1}' ]]
    [[ "$(jq -r '.dsseEnvelope.payload | @base64d | fromjson | .subject[0].digest.sha256' <(tail -n1 "$a"))" == "$ha" ]]
    [[ "$(jq -r '.dsseEnvelope.payload | @base64d | fromjson | .subject[0].digest.sha256' <(tail -n1 "$b"))" == "$hb" ]]
    # A subject's bundle carries only its own metadata.
    ! grep -q "$hb" "$a"
    ! grep -q "$ha" "$b"
    # Each signed line was posted to the store; with no OCI target none were OCI-pushed.
    [[ "$(wc -l < "$TEST_DIR/store-pushed")" -eq 2 ]]
    [[ ! -s "$TEST_DIR/oci-pushed" ]]
}

@test "sign_metadata: assemble pushes each signed line as an OCI referrer when OCI_TARGET is set" {
    _stub_attest_tools
    local meta="$TEST_DIR/meta"; mkdir -p "$meta"
    printf '{"spdxVersion":"SPDX-2.3"}' > "$meta/sbom.spdx.json"
    printf '{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}' > "$meta/wrangle_attestation_metadata.json"
    local sha; sha="$(printf '0%.0s' {1..64})"
    # Container seeds the provenance from the OCI referrer.
    _dsse_line "https://slsa.dev/provenance/v1" > "$TEST_DIR/referrers.jsonl"
    cat > "$TEST_DIR/cosign" <<STUB
#!/bin/bash
[[ "\$1" == "download" ]] && { cat "$TEST_DIR/referrers.jsonl"; exit 0; }
for a in "\$@"; do [[ "\${prev:-}" == "--attestation" ]] && cat "\$a" >> "$TEST_DIR/oci-pushed"; prev="\$a"; done
exit 0
STUB
    chmod +x "$TEST_DIR/cosign"
    export PATH="$TEST_DIR:$PATH"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:$sha"
    export METADATA_ROOT="$meta"
    export SUBJECTS="sha256:$sha"
    export GITHUB_REPOSITORY="o/r"
    export BUNDLE_OUT="$TEST_DIR/bundles"

    wrangle_sign_and_assemble_bundles

    local bundle="$BUNDLE_OUT/sha256-$sha.intoto.jsonl"
    [[ -f "$bundle" ]]
    [[ "$(jq -r '.dsseEnvelope.payload | @base64d | fromjson | .predicateType' <(head -n1 "$bundle"))" == "https://slsa.dev/provenance/v1" ]]
    # The signed metadata line was pushed to the store and as an OCI referrer.
    [[ "$(wc -l < "$TEST_DIR/store-pushed")" -eq 1 ]]
    [[ "$(wc -l < "$TEST_DIR/oci-pushed")" -eq 1 ]]
}

@test "sign_metadata: assemble fails closed on a missing metadata dir" {
    export METADATA_ROOT="$TEST_DIR/absent"
    export SUBJECTS="sha256:$(printf '0%.0s' {1..64})"
    export BUNDLE_OUT="$TEST_DIR/bundles"
    export BUNDLE_IN="$TEST_DIR/provenance.jsonl"; printf '{"provenance":1}\n' > "$BUNDLE_IN"
    export OCI_TARGET=""
    run wrangle_sign_and_assemble_bundles
    [[ "$status" -ne 0 ]]
}

@test "sign_metadata: assemble fails closed when a subject yields no signed metadata" {
    # A wrangle-attest that produces an empty out file must abort — never an
    # incomplete bundle missing its metadata.
    cat > "$TEST_DIR/wrangle-attest" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in --out=*) : > "${a#--out=}";; esac; done
STUB
    chmod +x "$TEST_DIR/wrangle-attest"
    export PATH="$TEST_DIR:$PATH"
    local meta="$TEST_DIR/meta"; mkdir -p "$meta"
    printf '{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}' > "$meta/wrangle_attestation_metadata.json"
    export METADATA_ROOT="$meta"
    export SUBJECTS="sha256:$(printf '0%.0s' {1..64})"
    export BUNDLE_OUT="$TEST_DIR/bundles"
    export BUNDLE_IN="$TEST_DIR/provenance.jsonl"; printf '{"provenance":1}\n' > "$BUNDLE_IN"
    export OCI_TARGET=""
    export GITHUB_REPOSITORY="o/r"
    run wrangle_sign_and_assemble_bundles
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no signed metadata"* ]]
}
