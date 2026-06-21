#!/usr/bin/env bats

# Tests for actions/attest_provenance/action.yml — the composite that owns the
# attest-job wiring the go/npm/python reusable build workflows shared.
# Structural assertions: the names computation, the dist download, the
# attest-build-provenance call, the jsonl staging, and the bundle upload.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ACTION="$REPO_ROOT/actions/attest_provenance/action.yml"
}

@test "attest_provenance: computes names via lib/derive_names.sh" {
    run grep -F 'lib/derive_names.sh' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_provenance: downloads dist and attests via attest-build-provenance" {
    run grep -F 'name: ${{ steps.names.outputs.dist }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'actions/attest-build-provenance@' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_provenance: threads both subject inputs to attest-build-provenance" {
    # go passes subject-checksums, npm/python pass subject-path; the unused one
    # is empty and ignored by the upstream action.
    run grep -F 'subject-checksums: ${{ inputs.subject-checksums }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'subject-path: ${{ inputs.subject-path }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_provenance: rejects zero or both subjects" {
    bash -c '
        set -euo pipefail
        SUBJECT_CHECKSUMS="a"; SUBJECT_PATH="b"
        if [[ -n "$SUBJECT_CHECKSUMS" && -n "$SUBJECT_PATH" ]] || [[ -z "$SUBJECT_CHECKSUMS" && -z "$SUBJECT_PATH" ]]; then exit 1; fi
    ' && status=0 || status=$?
    [ "$status" -eq 1 ]
    bash -c '
        set -euo pipefail
        SUBJECT_CHECKSUMS=""; SUBJECT_PATH=""
        if [[ -n "$SUBJECT_CHECKSUMS" && -n "$SUBJECT_PATH" ]] || [[ -z "$SUBJECT_CHECKSUMS" && -z "$SUBJECT_PATH" ]]; then exit 1; fi
    ' && status=0 || status=$?
    [ "$status" -eq 1 ]
    bash -c '
        set -euo pipefail
        SUBJECT_CHECKSUMS="a"; SUBJECT_PATH=""
        if [[ -n "$SUBJECT_CHECKSUMS" && -n "$SUBJECT_PATH" ]] || [[ -z "$SUBJECT_CHECKSUMS" && -z "$SUBJECT_PATH" ]]; then exit 1; fi
    ' && status=0 || status=$?
    [ "$status" -eq 0 ]
    bash -c '
        set -euo pipefail
        SUBJECT_CHECKSUMS=""; SUBJECT_PATH="b"
        if [[ -n "$SUBJECT_CHECKSUMS" && -n "$SUBJECT_PATH" ]] || [[ -z "$SUBJECT_CHECKSUMS" && -z "$SUBJECT_PATH" ]]; then exit 1; fi
    ' && status=0 || status=$?
    [ "$status" -eq 0 ]
}

@test "attest_provenance: stages jsonl and uploads the provenance-bundle artifact" {
    run grep -F 'jq -c . "$BUNDLE_PATH" > "$RUNNER_TEMP/provenance.jsonl"' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'name: ${{ steps.names.outputs.provenance-bundle }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_provenance: outputs the provenance-bundle artifact name" {
    run grep -F 'value: ${{ steps.names.outputs.provenance-bundle }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_provenance: downloads the pre-verify metadata for signing" {
    run grep -F 'name: ${{ steps.names.outputs.metadata-pre }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_provenance: installs the attest tools and signs the metadata" {
    run grep -F 'install_tools.sh' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'resolve_subjects.sh' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'sign_metadata.sh' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_provenance: threads GITHUB_TOKEN and COMMIT into the sign step" {
    # bnd needs the token to auth the store push; COMMIT lands in the scan/v1 envelope.
    run grep -F 'GITHUB_TOKEN: ${{ github.token }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'COMMIT: ${{ github.sha }}' "$ACTION"
    [ "$status" -eq 0 ]
}

@test "attest_provenance: uploads and outputs the signed-metadata artifact" {
    run grep -F 'name: ${{ steps.names.outputs.signed-metadata }}' "$ACTION"
    [ "$status" -eq 0 ]
    run grep -F 'value: ${{ steps.names.outputs.signed-metadata }}' "$ACTION"
    [ "$status" -eq 0 ]
}

# M1 — the attest job runs no adopter-controlled code: it only downloads the
# already-built dist + metadata and runs attest-provenance + wrangle-attest over
# them. Guard against a future executable step (run:/uses:) that invokes a
# caller build/test hook. Scope to step bodies so an input description that
# merely names a tool (e.g. "goreleaser's dist/checksums.txt") is not flagged.
@test "attest_provenance: runs no adopter build/test hook (trust boundary)" {
    run grep -Ei '^[[:space:]]*(run:|- uses:|uses:).*(goreleaser|docker build|npm (run |test|ci)|python -m build|pytest|setup-script)' "$ACTION"
    [ "$status" -ne 0 ]
}
