#!/usr/bin/env bats

# Tests for lib/sign_metadata.sh — the attest-job glue that seeds the provenance,
# drives `wrangle-attest assemble` (which signs the build metadata and assembles
# the per-artifact <artifact>.intoto.jsonl bundles), and delivers each signed line
# to the GitHub attestation store and the image's OCI referrers (#566).
#
# The engine is stubbed (assemble requires --sign, whose keyless flow needs
# OIDC/network; go test ./wrangle-attest/ covers its behavior), as are bnd and
# cosign (store/OCI pushes need network). The pure helpers (provenance, bundle-name,
# arg vectors) run with no real tools.
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
    # Signing always containerizes; make the toolbox path transparent so the
    # assemble/provenance tests exercise their tool stubs. Recording-docker tests override.
    wrangle_stub_toolbox_transparent
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

# A cosign whose `download attestation` emits $TEST_DIR/referrers.jsonl and whose
# `attach attestation` records the pushed line.
_stub_cosign() {
    cat > "$TEST_DIR/cosign" <<STUB
#!/bin/bash
[[ "\$1" == "download" && "\$2" == "attestation" ]] && { cat "$TEST_DIR/referrers.jsonl"; exit 0; }
prev=""
for a in "\$@"; do [[ "\$prev" == "--attestation" ]] && cat "\$a" >> "$TEST_DIR/oci-pushed"; prev="\$a"; done
exit 0
STUB
    chmod +x "$TEST_DIR/cosign"
    : > "$TEST_DIR/oci-pushed"
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

# --- assemble args ---

@test "sign_metadata: assemble args carry the metadata-root, subjects, commit, sign, bundle dir, and statements out" {
    export METADATA_ROOT="$TEST_DIR/meta" COMMIT="deadbeef" BUNDLE_OUT="$TEST_DIR/bundles" OCI_TARGET=""
    mapfile -t args < <(wrangle_assemble_args "$TEST_DIR/subjects" "$TEST_DIR/provenance" "$TEST_DIR/stmts")
    [[ "${args[0]}" == "assemble" ]]
    printf '%s\n' "${args[@]}" | grep -qx -- "--metadata-root=$TEST_DIR/meta"
    printf '%s\n' "${args[@]}" | grep -qx -- "--subjects-file=$TEST_DIR/subjects"
    printf '%s\n' "${args[@]}" | grep -qx -- "--provenance=$TEST_DIR/provenance"
    printf '%s\n' "${args[@]}" | grep -qx -- "--commit=deadbeef"
    printf '%s\n' "${args[@]}" | grep -qx -- "--sign"
    printf '%s\n' "${args[@]}" | grep -qx -- "--bundle-dir=$TEST_DIR/bundles"
    printf '%s\n' "${args[@]}" | grep -qx -- "--statements-out=$TEST_DIR/stmts"
}

@test "sign_metadata: assemble args hand the raw referrers to the engine for an OCI target" {
    export METADATA_ROOT="$TEST_DIR/meta" BUNDLE_OUT="$TEST_DIR/bundles"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:abc"
    mapfile -t args < <(wrangle_assemble_args "$TEST_DIR/subjects" "$TEST_DIR/provenance" "$TEST_DIR/stmts")
    printf '%s\n' "${args[@]}" | grep -qx -- "--provenance-referrers=$TEST_DIR/provenance"
    ! printf '%s\n' "${args[@]}" | grep -qx -- "--provenance=$TEST_DIR/provenance"
}

# --- provenance ---

@test "sign_metadata: provenance copies BUNDLE_IN when no OCI target" {
    export BUNDLE_IN="$TEST_DIR/provenance.jsonl"
    printf 'PROVLINE\n' > "$BUNDLE_IN"
    export OCI_TARGET=""
    local provenance="$TEST_DIR/provenance.jsonl"
    wrangle_stage_provenance "$provenance"
    [[ "$(cat "$provenance")" == "PROVLINE" ]]
    [[ "$(cat "$BUNDLE_IN")" == "PROVLINE" ]]
}

@test "sign_metadata: provenance fails closed when BUNDLE_IN is missing or empty" {
    export OCI_TARGET=""
    export BUNDLE_IN="$TEST_DIR/absent.jsonl"
    run wrangle_stage_provenance "$TEST_DIR/provenance.jsonl"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"provenance"* ]]
}

@test "sign_metadata: provenance passes the image's raw attestation referrers through for an OCI target" {
    # cosign download returns ALL referrers (a prior run may have left a VSA on the
    # digest); the engine filters them to the provenance, so the provenance is unfiltered.
    {
        _dsse_line "https://slsa.dev/provenance/v1"
        _dsse_line "https://slsa.dev/verification_summary/v1"
    } > "$TEST_DIR/referrers.jsonl"
    _stub_cosign
    export OCI_TARGET="ghcr.io/o/r/img@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    local provenance="$TEST_DIR/provenance.jsonl"
    wrangle_stage_provenance "$provenance"
    diff "$TEST_DIR/referrers.jsonl" "$provenance"
}

# --- assemble bundles ---

# bnd/cosign record their pushes; the engine stub emits the bundles + signed lines.
_stub_delivery_tools() {
    cat > "$TEST_DIR/bnd" <<STUB
#!/bin/bash
[[ "\$1" == "push" ]] && { cat "\$4" >> "$TEST_DIR/store-pushed"; exit 0; }
exit 0
STUB
    chmod +x "$TEST_DIR/bnd"
    : > "$TEST_DIR/store-pushed"
    _stub_cosign
    wrangle_stub_attest_assemble
}

@test "sign_metadata: assemble writes one bundle per subject (provenance + signed metadata) and pushes each line to the store" {
    _stub_delivery_tools
    local meta="$TEST_DIR/meta"; mkdir -p "$meta"
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
    # Each bundle = the shared provenance + that subject's signed metadata.
    [[ "$(head -n1 "$a")" == '{"provenance":1}' ]]
    [[ "$(jq -r '.dsseEnvelope.payload | @base64d | fromjson | .subject[0].digest.sha256' <(tail -n1 "$a"))" == "$ha" ]]
    [[ "$(jq -r '.dsseEnvelope.payload | @base64d | fromjson | .subject[0].digest.sha256' <(tail -n1 "$b"))" == "$hb" ]]
    # Both subjects went to the engine in one invocation — one OIDC/Fulcio flow.
    [[ "$(grep -c '^assemble$' "$TEST_DIR/assemble-args")" -eq 1 ]]
    # Each signed line was posted to the store; with no OCI target none were OCI-pushed.
    [[ "$(wc -l < "$TEST_DIR/store-pushed")" -eq 2 ]]
    [[ ! -s "$TEST_DIR/oci-pushed" ]]
}

@test "sign_metadata: assemble pushes each signed line as an OCI referrer when OCI_TARGET is set" {
    local meta="$TEST_DIR/meta"; mkdir -p "$meta"
    local sha; sha="$(printf '0%.0s' {1..64})"
    # Container seeds the provenance from the image's referrers.
    _dsse_line "https://slsa.dev/provenance/v1" > "$TEST_DIR/referrers.jsonl"
    _stub_delivery_tools
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

@test "sign_metadata: assemble fails closed when the engine fails (no bundles, no pushes)" {
    # The engine owns every assembly invariant (missing metadata dir, empty subject
    # set, unreadable provenance, duplicate bundle basename, a subject with no signed
    # statement); a non-zero engine exit must abort the job with nothing delivered.
    _stub_delivery_tools
    cat > "$TEST_DIR/wrangle-attest" <<'STUB'
#!/bin/bash
exit 2
STUB
    chmod +x "$TEST_DIR/wrangle-attest"
    export METADATA_ROOT="$TEST_DIR/absent"
    local sha; sha="$(printf '0%.0s' {1..64})"
    export SUBJECTS="sha256:$sha"
    export BUNDLE_OUT="$TEST_DIR/bundles"
    export BUNDLE_IN="$TEST_DIR/provenance.jsonl"; printf '{"provenance":1}\n' > "$BUNDLE_IN"
    export OCI_TARGET=""
    export GITHUB_REPOSITORY="o/r"
    run wrangle_sign_and_assemble_bundles
    [[ "$status" -ne 0 ]]
    [[ ! -e "$BUNDLE_OUT" || -z "$(ls -A "$BUNDLE_OUT")" ]]
    [[ ! -s "$TEST_DIR/store-pushed" ]]
    [[ ! -s "$TEST_DIR/oci-pushed" ]]
}

# --- containerized signing (the attest-toolbox image under the token grant) ---

_toolbox_image="ghcr.io/tomhennen/wrangle/attest-toolbox@sha256:0000000000000000000000000000000000000000000000000000000000000000"

# docker records its argv; gh returns a PASSED L3 VSA for the toolbox image; curl
# mints a fixed sigstore JWT; the catalog carries the token: sigstore grant.
_stub_toolbox_container() {
    cat > "$TEST_DIR/docker" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$TEST_DIR/docker.args"
EOF
    cat > "$TEST_DIR/gh" <<EOF
#!/bin/bash
cat <<JSON
[{"verificationResult":{"statement":{"predicate":{"verificationResult":"PASSED","resourceUri":"$_toolbox_image","verifiedLevels":["SLSA_BUILD_LEVEL_3"]}}}}]
JSON
EOF
    cat > "$TEST_DIR/curl" <<'EOF'
#!/bin/bash
printf '{"value":"MINTED-SIGSTORE-JWT"}\n'
EOF
    chmod +x "$TEST_DIR/docker" "$TEST_DIR/gh" "$TEST_DIR/curl"
    cat > "$TEST_DIR/catalog.json" <<JSON
{"tools":{"attest-toolbox":{"kind":"attest","image":"$_toolbox_image","network":"egress","token":"sigstore"}}}
JSON
    export PATH="$TEST_DIR:$PATH"
    export WRANGLE_CATALOG="$TEST_DIR/catalog.json"
    export ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token"
    export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-bearer-secret"
    export GITHUB_TOKEN="registry-token"
}

# The env every assemble run reads, with the provenance already on disk (a recording
# docker never runs the real cosign download).
_export_assemble_env() {
    local meta="$TEST_DIR/meta"; mkdir -p "$meta"
    printf '{}' > "$meta/wrangle_attestation_metadata.json"
    export METADATA_ROOT="$meta" COMMIT="abc123" OCI_TARGET="" GITHUB_REPOSITORY="o/r"
    export BUNDLE_OUT="$TEST_DIR/bundles"
    export BUNDLE_IN="$TEST_DIR/provenance.jsonl"; printf '{"provenance":1}\n' > "$BUNDLE_IN"
    local sha; sha="$(printf '0%.0s' {1..64})"
    export SUBJECTS="sha256:$sha"
}

@test "sign_metadata: metadata signing runs in-container with a name-threaded sigstore token" {
    _stub_toolbox_container
    _export_assemble_env
    wrangle_sign_and_assemble_bundles
    # wrangle-attest assemble --sign ran inside the VSA-gated toolbox image.
    grep -q -- "$_toolbox_image wrangle-attest assemble" "$TEST_DIR/docker.args"
    grep -q -- "--sign" "$TEST_DIR/docker.args"
    # Only the sigstore token is threaded, by name; never the request vars, never
    # the minted value on argv, never the registry token.
    grep -q -- "-e SIGSTORE_ID_TOKEN" "$TEST_DIR/docker.args"
    ! grep -q "MINTED-SIGSTORE-JWT" "$TEST_DIR/docker.args"
    ! grep -q "ACTIONS_ID_TOKEN_REQUEST" "$TEST_DIR/docker.args"
    ! grep -q -- "-e GITHUB_TOKEN" "$TEST_DIR/docker.args"
    # The workspace and RUNNER_TEMP are mounted and the working dir is set, so the
    # same (relative-in-prod) metadata/subject/out paths resolve as they do in-job.
    grep -q -- "-w $PWD" "$TEST_DIR/docker.args"
    grep -q -- "--mount type=bind,source=$RUNNER_TEMP,target=$RUNNER_TEMP" "$TEST_DIR/docker.args"
}

@test "sign_metadata: store push runs in-container with the registry token, no sigstore token" {
    _stub_toolbox_container
    export GITHUB_REPOSITORY="o/r"
    printf 'stmt\n' > "$TEST_DIR/line.json"
    wrangle_push_store "$TEST_DIR/line.json"
    grep -q -- "$_toolbox_image bnd push github o/r" "$TEST_DIR/docker.args"
    grep -q -- "-e GITHUB_TOKEN" "$TEST_DIR/docker.args"
    # A store push is not a signing op — no sigstore token, and the GitHub API
    # needs no registry-login mount.
    ! grep -q -- "-e SIGSTORE_ID_TOKEN" "$TEST_DIR/docker.args"
    ! grep -q -- "docker-config" "$TEST_DIR/docker.args"
}

@test "sign_metadata: OCI referrer push runs in-container with the job's registry login" {
    _stub_toolbox_container
    local sha; sha="$(printf '0%.0s' {1..64})"
    export OCI_TARGET="ghcr.io/o/r/img@sha256:$sha"
    export HOME="$TEST_DIR"; mkdir -p "$TEST_DIR/.docker"
    printf 'stmt\n' > "$TEST_DIR/line.json"
    wrangle_push_oci_referrer "$TEST_DIR/line.json"
    grep -q -- "$_toolbox_image cosign attach attestation" "$TEST_DIR/docker.args"
    grep -q -- "-e GITHUB_TOKEN" "$TEST_DIR/docker.args"
    grep -q -- "-e DOCKER_CONFIG=/wrangle/docker-config" "$TEST_DIR/docker.args"
    ! grep -q -- "-e SIGSTORE_ID_TOKEN" "$TEST_DIR/docker.args"
}

@test "sign_metadata: a missing token: sigstore grant fails closed (no docker, no in-job sign)" {
    _stub_toolbox_container
    # Strip the grant: signing must fail closed, never fall back to an in-job sign.
    printf '{"tools":{"attest-toolbox":{"kind":"attest","image":"%s","network":"egress"}}}\n' \
        "$_toolbox_image" > "$TEST_DIR/catalog.json"
    cat > "$TEST_DIR/wrangle-attest" <<EOF
#!/bin/bash
touch "$TEST_DIR/attest.called"
EOF
    chmod +x "$TEST_DIR/wrangle-attest"
    _export_assemble_env
    run wrangle_sign_and_assemble_bundles
    [ "$status" -ne 0 ]
    grep -q "capability required to sign" <<< "$output"
    [ ! -f "$TEST_DIR/docker.args" ]
    [ ! -f "$TEST_DIR/attest.called" ]
}

@test "sign_metadata: relative METADATA_ROOT never becomes an invalid relative bind mount (blocker guard)" {
    _stub_toolbox_container
    # wrangle sets METADATA_ROOT/SUBJECTS relative; a bind mount source must be
    # absolute, so the signer mounts the workspace + sets -w, never a relative source.
    cd "$TEST_DIR"
    _export_assemble_env
    mkdir -p metadata; printf '{}' > metadata/wrangle_attestation_metadata.json
    export METADATA_ROOT="metadata" BUNDLE_OUT="bundles"
    wrangle_sign_and_assemble_bundles
    # Every bind mount source is an absolute host path (starts with /); none is relative.
    ! grep -qE -- 'source=[^/]' "$TEST_DIR/docker.args"
    # The workspace is mounted and set as the container working dir instead.
    grep -q -- "-w $TEST_DIR" "$TEST_DIR/docker.args"
    grep -q -- "--mount type=bind,source=$TEST_DIR,target=$TEST_DIR" "$TEST_DIR/docker.args"
}

@test "sign_metadata: metadata signing fails closed on a token-mint failure (no docker, no in-job fallback)" {
    _stub_toolbox_container
    # Mint fails when the ambient OIDC request vars are absent; the grant+opt-in
    # path must NOT fall back to an in-job wrangle-attest.
    unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
    cat > "$TEST_DIR/wrangle-attest" <<EOF
#!/bin/bash
touch "$TEST_DIR/attest.called"
EOF
    chmod +x "$TEST_DIR/wrangle-attest"
    _export_assemble_env
    run wrangle_sign_and_assemble_bundles
    [ "$status" -ne 0 ]
    [ ! -f "$TEST_DIR/docker.args" ]
    [ ! -f "$TEST_DIR/attest.called" ]
}
