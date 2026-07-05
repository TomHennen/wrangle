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
# cert must name as origin), VSA_DIR (directory holding the downloaded
# per-artifact <artifact>.intoto.jsonl bundles — one per released artifact).
set -euo pipefail
set -f

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=validate_inputs.sh
source "$SCRIPT_DIR/validate_inputs.sh"
# Toolbox dispatch (image resolution + VSA gate + hardened docker run), so ampel
# runs inside the curated attest-toolbox image.
# shellcheck source=../../lib/toolbox_run.sh
source "$SCRIPT_DIR/../../lib/toolbox_run.sh"

# Canonical: only this leaf dir is bind-mounted, so a "../.." path won't resolve in-container.
POLICY_DIR="$(cd "$SCRIPT_DIR/../../policies" && pwd)"
# Ships with this action, so its content is pinned by the action ref the
# caller chose — never fetched at verify time.
POLICY="$POLICY_DIR/wrangle-vsa-consumer-v1.hjson"
# Internal dogfood only: wrangle's own @main showcase builds aren't release-tag
# signed, so they can't satisfy the strict consumer policy's tag ref-anchor.
# This swaps in a policy that accepts any wrangle build ref. Adopters never set
# this — it stays unset, keeping the strict tag requirement.
if [[ "${WRANGLE_VSA_NON_STRICT:-}" == "1" ]]; then
    POLICY="$POLICY_DIR/wrangle-vsa-consumer-nonstrict-v1.hjson"
fi

die_verify() {
    printf 'wrangle/verify-vsa: VERIFICATION FAILED: %s\n' "$1" >&2
    exit 1
}

# Read the bundle via the jsonl: collector (not --attestation, which errors on a
# multi-statement file); ampel self-selects the VSA matching $file and fails the
# policy when none matches — so the missing-VSA case is fail-closed.
verify_one() {
    local file="$1" bundle="$2"
    # The policy ships outside the workspace/temp mounts, so bind its directory.
    wrangle_toolbox_exec --mount "$(dirname "$POLICY")" -- \
        ampel verify --subject "$file" \
        --policy "$POLICY" \
        --collector "jsonl:$bundle" \
        --context "sourceRepo:https://github.com/${REPO}" \
        --context "expectedResourceUri:${RESOURCE_URI}" \
        || die_verify "ampel rejected $file against $bundle"
}

main() {
    validate_inputs
    [[ -d "${VSA_DIR:-}" ]] \
        || die_input "VSA_DIR is not a directory: ${VSA_DIR:-<empty>} (did the bundle download fail?)"

    # Concatenate every downloaded bundle into one JSONL so ampel can self-select
    # the VSA for any subject. Enumerate via a temp file, not a process
    # substitution, so a find that dies mid-traversal fails closed.
    local bundle_listing combined bundle_file
    bundle_listing="$(mktemp)"
    if ! find "$VSA_DIR" -type f -name '*.intoto.jsonl' -print0 | sort -z > "$bundle_listing"; then
        rm -f "$bundle_listing"
        die_input "failed to enumerate bundles under $VSA_DIR"
    fi
    # Under RUNNER_TEMP so it lands inside a toolbox mount and ampel reads it.
    combined="$(mktemp "${RUNNER_TEMP:-/tmp}/wrangle-vsa-combined.XXXXXX")"
    while IFS= read -r -d '' bundle_file; do cat "$bundle_file" >> "$combined"; done < "$bundle_listing"
    rm -f "$bundle_listing"
    [[ -s "$combined" ]] \
        || { rm -f "$combined"; die_input "no VSA bundle found under $VSA_DIR (did the bundle download fail?)"; }

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

    for f in "${files[@]}"; do
        printf 'wrangle/verify-vsa: verifying %s against the bundle\n' "$f"
        verify_one "$f" "$combined"
    done
    rm -f "$combined"
    printf 'wrangle/verify-vsa: %d file(s) verified against PASSED VSAs signed for %s\n' \
        "${#files[@]}" "$REPO"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
