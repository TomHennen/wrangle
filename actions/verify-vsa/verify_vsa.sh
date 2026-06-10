#!/usr/bin/env bash
# Verify local artifact bytes against wrangle's signed VSA before the caller
# publishes those bytes. The VSA is the full policy verdict (provenance plus
# any other tenets the PolicySet checks), so this gates on "passed policy",
# not merely "wrangle built it". Fail-closed: a file with no VSA, a bad
# signature/identity, or a non-PASSED verdict fails the run.
#
# Env: ARTIFACT_PATH (file, or directory verified recursively), REPO
# (<owner>/<repo> the VSA's signing cert must name as origin), VSA_DIR
# (directory holding <artifact-basename>.intoto.jsonl files), SIGNER_WORKFLOW
# (optional <owner>/<repo>/<path>.yml; empty accepts any wrangle
# build_and_publish_* workflow).
set -euo pipefail
set -f

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=validate_inputs.sh
source "$SCRIPT_DIR/validate_inputs.sh"

# bnd signs the VSA keyless inside wrangle's reusable workflow, so that
# workflow (not the caller) is the cert SAN the identity check must match.
# Must stay equivalent to the identity in policies/wrangle-vsa-consumer-v1.hjson
# (divergence-fail test in test.bats).
WRANGLE_SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_[a-z]+\.yml@'
OIDC_ISSUER='https://token.actions.githubusercontent.com'
VSA_PREDICATE='https://slsa.dev/verification_summary/v1'

die_verify() {
    printf 'wrangle/verify-vsa: VERIFICATION FAILED: %s\n' "$1" >&2
    exit 1
}

# cosign checks signature, signer identity, origin repository, and that the
# blob's hash matches the VSA subject — but it does not read predicate
# fields, so the PASSED verdict needs a separate decode.
verify_one() {
    local file="$1" vsa="$2" identity_regex="$3"
    cosign verify-blob-attestation --bundle "$vsa" --new-bundle-format \
        --certificate-oidc-issuer "$OIDC_ISSUER" \
        --certificate-identity-regexp "$identity_regex" \
        --certificate-github-workflow-repository "$REPO" \
        --type "$VSA_PREDICATE" \
        "$file" \
        || die_verify "cosign rejected $file against $vsa"

    local verdict
    verdict="$(jq -r '.dsseEnvelope.payload | @base64d | fromjson | .predicate.verificationResult' "$vsa")" \
        || die_verify "could not decode VSA payload in $vsa"
    [[ "$verdict" == "PASSED" ]] \
        || die_verify "VSA for $file does not say PASSED (got: ${verdict})"
}

main() {
    validate_inputs
    [[ -d "${VSA_DIR:-}" ]] \
        || die_input "VSA_DIR is not a directory: ${VSA_DIR:-<empty>} (did the VSA artifact download fail?)"

    local -a files=()
    local f
    if [[ -f "$ARTIFACT_PATH" ]]; then
        files=("$ARTIFACT_PATH")
    elif [[ -d "$ARTIFACT_PATH" ]]; then
        # Enumerate via a temp file, not a process substitution: bash never
        # observes a process substitution's exit status, so a find that fails
        # mid-traversal (unreadable subdir) would silently verify only the
        # readable subset and pass — fail-open for this gate's contract.
        local listing
        listing="$(mktemp)"
        if ! find "$ARTIFACT_PATH" -type f -print0 | sort -z > "$listing"; then
            rm -f "$listing"
            die_input "failed to enumerate files under $ARTIFACT_PATH"
        fi
        while IFS= read -r -d '' f; do files+=("$f"); done < "$listing"
        rm -f "$listing"
    else
        die_input "not a regular file or directory: $ARTIFACT_PATH"
    fi
    (( ${#files[@]} > 0 )) \
        || die_input "no files to verify under $ARTIFACT_PATH — refusing to pass an empty set"

    # Anchored through '@' but deliberately not to a ref: the VSA comes from
    # this same run's artifacts, signed at whatever wrangle ref the caller
    # pinned — a tag anchor (like the README consumer commands use) would
    # break SHA- and branch-pinned callers.
    local identity_regex="$WRANGLE_SIGNER_REGEX"
    if [[ -n "${SIGNER_WORKFLOW:-}" ]]; then
        identity_regex="^https://github\\.com/${SIGNER_WORKFLOW//./\\.}@"
    fi

    local vsa
    for f in "${files[@]}"; do
        vsa="$VSA_DIR/$(basename "$f").intoto.jsonl"
        [[ -f "$vsa" ]] \
            || die_verify "no VSA found for $f (expected $vsa) — refusing to publish unverified bytes"
        printf 'wrangle/verify-vsa: verifying %s against %s\n' "$f" "$vsa"
        verify_one "$f" "$vsa" "$identity_regex"
    done
    printf 'wrangle/verify-vsa: %d file(s) verified against PASSED VSAs signed for %s\n' \
        "${#files[@]}" "$REPO"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
