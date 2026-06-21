#!/usr/bin/env bats

# Tests for the container attest-job metadata signing (issue #550 PR 3):
#   sign_metadata.sh — wrangle-attest --sign over the image digest + bnd store
#                      push + cosign OCI-referrer push, emitting the signed set.
#
# The shared orchestration lives in lib/sign_metadata.sh
# (wrangle_sign_and_assemble_bundles); this thin wrapper drives it with OCI_TARGET
# set, seeding the provenance from the OCI referrer and assembling the per-artifact
# bundle. wrangle-attest runs for real (it self-digests offline); bnd + cosign are
# stubbed because the keyless --sign + store/registry pushes need OIDC/network.
load "../../test/lib/bats_helpers"

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$DIR/../.." && pwd)"
    SIGN="$DIR/sign_metadata.sh"
    TEST_DIR="$(mktemp -d)"
    export DIR REPO_ROOT SIGN TEST_DIR

    META="$TEST_DIR/meta"
    mkdir -p "$META"
    printf '{"spdxVersion":"SPDX-2.3"}' > "$META/sbom.spdx.json"
    printf '{"predicate-type":"https://spdx.dev/Document","result-file":"sbom.spdx.json"}' \
        > "$META/wrangle_attestation_metadata.json"
    export META

    export RUNNER_TEMP="$TEST_DIR"
    export WRANGLE_BIN_DIR="$TEST_DIR/bin"
    export WRANGLE_RETRY_DELAY=0

    ATTEST_BIN="$(command -v wrangle-attest || echo "${WRANGLE_BIN_DIR}/wrangle-attest")"
    export ATTEST_BIN
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "attest_metadata_oci sign_metadata: signs the digest subject, assembles the bundle, and pushes to the store AND the OCI referrer" {
    [[ -x "$ATTEST_BIN" ]] || skip_or_fail "wrangle-attest not built"
    STUB_BIN="$TEST_DIR/stubbin"; mkdir -p "$STUB_BIN"
    # A wrapper that forwards to the real engine but drops --sign (offline).
    cat > "$STUB_BIN/wrangle-attest" << STUBA
#!/usr/bin/env bash
set -euo pipefail
args=()
for a in "\$@"; do [[ "\$a" == "--sign" ]] || args+=("\$a"); done
exec "$ATTEST_BIN" "\${args[@]}"
STUBA
    # bnd records each store push; cosign seeds the provenance on download and
    # records each OCI referrer attach.
    cat > "$STUB_BIN/bnd" << STUB
#!/usr/bin/env bash
[[ "\$1" == "push" && "\$2" == "github" ]] && { printf '%s\n' "\$4" >> "$TEST_DIR/pushed"; }
exit 0
STUB
    local seed_payload; seed_payload="$(printf '{"predicateType":"https://slsa.dev/provenance/v1","subject":[]}' | base64 | tr -d '\n')"
    printf '{"dsseEnvelope":{"payload":"%s"}}\n' "$seed_payload" > "$TEST_DIR/referrers.jsonl"
    cat > "$STUB_BIN/cosign" << STUB
#!/usr/bin/env bash
[[ "\$1" == "download" ]] && { cat "$TEST_DIR/referrers.jsonl"; exit 0; }
prev=""
for a in "\$@"; do [[ "\$prev" == "--attestation" ]] && printf '%s\n' "\$a" >> "$TEST_DIR/attached"; prev="\$a"; done
[[ "\$1" == "attach" ]] && printf '%s\n' "\$@" >> "$TEST_DIR/cosign-verbs"
exit 0
STUB
    chmod +x "$STUB_BIN/wrangle-attest" "$STUB_BIN/bnd" "$STUB_BIN/cosign"
    : > "$TEST_DIR/pushed"; : > "$TEST_DIR/attached"; : > "$TEST_DIR/cosign-verbs"

    local sha; sha="$(printf '0%.0s' {1..64})"
    PATH="$STUB_BIN:$PATH" SUBJECTS="sha256:$sha" METADATA_ROOT="$META" \
        BUNDLE_OUT="$TEST_DIR/bundles" GITHUB_REPOSITORY="o/r" COMMIT="abc123" \
        OCI_TARGET="ghcr.io/o/r/img@sha256:$sha" run "$SIGN"
    [ "$status" -eq 0 ]
    # The bundle = provenance seed + signed metadata; one store push, one OCI attach.
    local bundle="$TEST_DIR/bundles/sha256-$sha.intoto.jsonl"
    [ -s "$bundle" ]
    [ "$(jq -r '.dsseEnvelope.payload | @base64d | fromjson | .predicateType' <(head -n1 "$bundle"))" = "https://slsa.dev/provenance/v1" ]
    [ "$(wc -l < "$TEST_DIR/pushed")" -eq 1 ]
    [ "$(wc -l < "$TEST_DIR/attached")" -eq 1 ]
    grep -q '^attach' "$TEST_DIR/cosign-verbs"
}

@test "attest_metadata_oci sign_metadata: a missing metadata dir fails closed" {
    local sha; sha="$(printf '0%.0s' {1..64})"
    SUBJECTS="sha256:$sha" METADATA_ROOT="$TEST_DIR/absent" \
        BUNDLE_OUT="$TEST_DIR/bundles" GITHUB_REPOSITORY="o/r" \
        OCI_TARGET="ghcr.io/o/r/img@sha256:$sha" run "$SIGN"
    [ "$status" -ne 0 ]
}
