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

# bnd signs the VSA keyless inside wrangle's reusable workflow, so that
# workflow (not the caller) is the cert SAN the identity check must match.
WRANGLE_SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_[a-z]+\.yml@'
OIDC_ISSUER='https://token.actions.githubusercontent.com'
VSA_PREDICATE='https://slsa.dev/verification_summary/v1'

die_input() {
    printf 'wrangle/verify-artifact: %s\n' "$1" >&2
    exit 2
}

die_verify() {
    printf 'wrangle/verify-artifact: VERIFICATION FAILED: %s\n' "$1" >&2
    exit 1
}

collect_files() {
    local path="$1"
    if [[ -f "$path" ]]; then
        printf '%s\0' "$path"
    elif [[ -d "$path" ]]; then
        find "$path" -type f -print0 | sort -z
    else
        return 1
    fi
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

    local payload
    payload="$(jq -r '.dsseEnvelope.payload' "$vsa" | base64 -d)" \
        || die_verify "could not decode VSA payload in $vsa"
    jq -e '.predicate.verificationResult == "PASSED"' <<<"$payload" >/dev/null \
        || die_verify "VSA for $file does not say PASSED"
}

main() {
    [[ -n "${ARTIFACT_PATH:-}" ]] || die_input "ARTIFACT_PATH is required"
    [[ "${REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || die_input "REPO must be <owner>/<repo>, got: ${REPO:-<empty>}"
    [[ -d "${VSA_DIR:-}" ]] \
        || die_input "VSA_DIR is not a directory: ${VSA_DIR:-<empty>} (did the VSA artifact download fail?)"
    if [[ -n "${SIGNER_WORKFLOW:-}" ]] \
        && [[ ! "$SIGNER_WORKFLOW" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9._/-]+\.(yml|yaml)$ ]]; then
        die_input "SIGNER_WORKFLOW must be <owner>/<repo>/<path-to-workflow>.yml, got: $SIGNER_WORKFLOW"
    fi

    local -a files=()
    local f
    while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(collect_files "$ARTIFACT_PATH" || true)
    [[ -e "$ARTIFACT_PATH" ]] || die_input "no such file or directory: $ARTIFACT_PATH"
    (( ${#files[@]} > 0 )) \
        || die_input "no files to verify under $ARTIFACT_PATH — refusing to pass an empty set"

    local identity_regex="$WRANGLE_SIGNER_REGEX"
    if [[ -n "${SIGNER_WORKFLOW:-}" ]]; then
        identity_regex="^https://github\\.com/${SIGNER_WORKFLOW//./\\.}@"
    fi

    local vsa
    for f in "${files[@]}"; do
        vsa="$VSA_DIR/$(basename "$f").intoto.jsonl"
        [[ -f "$vsa" ]] \
            || die_verify "no VSA found for $f (expected $vsa) — refusing to publish unverified bytes"
        printf 'wrangle/verify-artifact: verifying %s against %s\n' "$f" "$vsa"
        verify_one "$f" "$vsa" "$identity_regex"
    done
    printf 'wrangle/verify-artifact: %d file(s) verified against PASSED VSAs signed for %s\n' \
        "${#files[@]}" "$REPO"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
