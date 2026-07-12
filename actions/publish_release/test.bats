#!/usr/bin/env bats

# Structural tests for actions/publish_release/action.yml — the shared,
# least-privileged publish composite the go/python/npm workflows run as their
# release-upload job in both attested and unattested modes. It downloads dist +
# the metadata artifact and branches on attest-and-verify to call run_verify.sh
# attach (attested) or attach-unattested (unattested). The gh/release logic lives
# in run_verify.sh; this asserts the wiring.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ACTION="$REPO_ROOT/actions/publish_release/action.yml"
}

@test "publish_release: computes names via lib/derive_names.sh" {
    run grep -F 'lib/derive_names.sh' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "publish_release: downloads dist and the metadata artifact" {
    run grep -F 'name: ${{ steps.names.outputs.dist }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'name: ${{ steps.names.outputs.metadata }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "publish_release: branches on attest-and-verify between attach and attach-unattested" {
    run grep -F "run_verify.sh\" attach" "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F "run_verify.sh\" attach-unattested" "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'ATTESTATION: ${{ inputs.attest-and-verify }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "publish_release: gh needs GH_REPO and a token (no checkout in this job)" {
    run grep -F 'GH_REPO: ${{ github.repository }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'GH_TOKEN: ${{ github.token }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "publish_release: requests no signing inputs (it only publishes)" {
    run grep -E 'id-token|attestations|oci-target' "$ACTION"
    [ "$status" -ne 0 ]
}
