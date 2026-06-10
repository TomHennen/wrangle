#!/usr/bin/env bash
# Verify local artifact bytes against their GitHub-stored SLSA provenance
# with `gh attestation verify`, before the caller publishes those bytes.
# Fail-closed: any file without a passing attestation fails the run.
#
# Env: ARTIFACT_PATH (file, or directory verified recursively), REPO
# (<owner>/<repo> whose attestation store is queried), SIGNER_WORKFLOW
# (optional <owner>/<repo>/<path>.yml; empty accepts any wrangle
# build_and_publish_* workflow), GH_TOKEN (consumed by gh).
set -euo pipefail
set -f

# Reusable-workflow-signed provenance carries the reusable workflow (not the
# caller) as the Sigstore SAN, so the identity check must name wrangle.
WRANGLE_SIGNER_REGEX='^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_[a-z]+\.yml@'

fail() {
    printf 'wrangle/verify-artifact: %s\n' "$1" >&2
    exit 2
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

main() {
    [[ -n "${ARTIFACT_PATH:-}" ]] || fail "ARTIFACT_PATH is required"
    [[ "${REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || fail "REPO must be <owner>/<repo>, got: ${REPO:-<empty>}"
    if [[ -n "${SIGNER_WORKFLOW:-}" ]] \
        && [[ ! "$SIGNER_WORKFLOW" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9._/-]+\.(yml|yaml)$ ]]; then
        fail "SIGNER_WORKFLOW must be <owner>/<repo>/<path-to-workflow>.yml, got: $SIGNER_WORKFLOW"
    fi

    local -a files=()
    local f
    while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(collect_files "$ARTIFACT_PATH" || true)
    [[ -e "$ARTIFACT_PATH" ]] || fail "no such file or directory: $ARTIFACT_PATH"
    (( ${#files[@]} > 0 )) \
        || fail "no files to verify under $ARTIFACT_PATH — refusing to pass an empty set"

    local -a id_args
    if [[ -n "${SIGNER_WORKFLOW:-}" ]]; then
        id_args=(--signer-workflow "$SIGNER_WORKFLOW")
    else
        id_args=(--cert-identity-regex "$WRANGLE_SIGNER_REGEX")
    fi

    for f in "${files[@]}"; do
        printf 'wrangle/verify-artifact: verifying %s\n' "$f"
        gh attestation verify "$f" --repo "$REPO" "${id_args[@]}"
    done
    printf 'wrangle/verify-artifact: %d file(s) verified against provenance for %s\n' \
        "${#files[@]}" "$REPO"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
