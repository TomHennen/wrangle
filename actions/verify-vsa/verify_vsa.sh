#!/usr/bin/env bash
# Verify local artifact bytes against wrangle's signed VSA before the caller
# publishes those bytes. The VSA is the full policy verdict (provenance plus
# any other tenets the PolicySet checks), so this gates on "passed policy",
# not merely "wrangle built it". Fail-closed: a file with no VSA, a bad
# signature/identity, a wrong origin repo, or a non-PASSED verdict fails the
# run.
#
# Each file gets one `ampel verify` against wrangle-vsa-consumer-v1 — the
# same check downstream consumers run.
#
# Env: ARTIFACT_PATH (file, or directory verified recursively), RESOURCE_URI
# (the purl/OCI ref the VSA's resourceUri must equal — pipe the build
# workflow's resource-uri output), REPO (<owner>/<repo> the VSA's signing
# cert must name as origin), VSA_DIR (directory holding
# <artifact-basename>.intoto.jsonl files).
set -euo pipefail
set -f

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=validate_inputs.sh
source "$SCRIPT_DIR/validate_inputs.sh"
# shellcheck source=../../lib/env.sh
source "$SCRIPT_DIR/../../lib/env.sh"

# Ships with this action, so its content is pinned by the action ref the
# caller chose — never fetched at verify time.
POLICY="$SCRIPT_DIR/../../policies/wrangle-vsa-consumer-v1.hjson"

die_verify() {
    printf 'wrangle/verify-vsa: VERIFICATION FAILED: %s\n' "$1" >&2
    exit 1
}

verify_one() {
    local file="$1" vsa="$2"
    ampel verify --subject "$file" \
        --policy "$POLICY" \
        --attestation "$vsa" \
        --context "sourceRepo:https://github.com/${REPO}" \
        --context "expectedResourceUri:${RESOURCE_URI}" \
        || die_verify "ampel rejected $file against $vsa"
}

main() {
    validate_inputs
    [[ -d "${VSA_DIR:-}" ]] \
        || die_input "VSA_DIR is not a directory: ${VSA_DIR:-<empty>} (did the VSA artifact download fail?)"
    command -v ampel >/dev/null 2>&1 \
        || die_input "ampel not found on PATH (did the install step run?)"

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

    local vsa
    for f in "${files[@]}"; do
        vsa="$VSA_DIR/$(basename "$f").intoto.jsonl"
        [[ -f "$vsa" ]] \
            || die_verify "no VSA found for $f (expected $vsa) — refusing to publish unverified bytes"
        printf 'wrangle/verify-vsa: verifying %s against %s\n' "$f" "$vsa"
        verify_one "$f" "$vsa"
    done
    printf 'wrangle/verify-vsa: %d file(s) verified against PASSED VSAs signed for %s\n' \
        "${#files[@]}" "$REPO"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
