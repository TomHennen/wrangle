#!/usr/bin/env bash
# Verify local artifact bytes against wrangle's signed VSA before the caller
# publishes those bytes. The VSA is the full policy verdict (provenance plus
# any other tenets the PolicySet checks), so this gates on "passed policy",
# not merely "wrangle built it". Fail-closed: a file with no VSA, a bad
# signature/identity, a wrong origin repo, or a non-PASSED verdict fails the
# run.
#
# Each file is checked with `ampel verify` against the wrangle-vsa-gate-v1
# PolicySet shipped alongside this action — the same engine and identity
# wrangle recommends to downstream consumers, minus the resourceUri pin the
# pre-publish gate cannot know. ampel binds the file's hash to the VSA
# subject, the keyless signer identity, the origin repository (the policy's
# sourceRepositoryUriMatch against REPO), and the PASSED verdict in one call.
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
# shellcheck source=../../lib/env.sh
source "$SCRIPT_DIR/../../lib/env.sh"

# The PolicySet ships with this action, so its content is pinned by the
# action ref the caller chose — never fetched at verify time.
GATE_POLICY="$SCRIPT_DIR/../../policies/wrangle-vsa-gate-v1.hjson"

die_verify() {
    printf 'wrangle/verify-vsa: VERIFICATION FAILED: %s\n' "$1" >&2
    exit 1
}

# Resolve the policy to evaluate: the shipped gate policy as-is, or — when
# SIGNER_WORKFLOW narrows the signer — a derived copy with the identity
# regexp replaced. ampel has no CLI override for a policy-defined identity
# (--signer is ignored when the policy declares identities), so narrowing
# must rewrite the policy. The replacement is fail-closed: if the derived
# file doesn't contain exactly the narrowed identity, or still matches the
# broad one, we abort rather than verify against the wrong signer set.
wrangle_gate_policy() {
    local out_dir="$1"
    if [[ -z "${SIGNER_WORKFLOW:-}" ]]; then
        printf '%s\n' "$GATE_POLICY"
        return 0
    fi
    # Anchored through '@' but deliberately not to a ref: the VSA comes from
    # this same run's artifacts, signed at whatever wrangle ref the caller
    # pinned — a tag anchor (like the README consumer commands use) would
    # break SHA- and branch-pinned callers.
    local escaped="${SIGNER_WORKFLOW//./"\\\\."}"
    local derived="$out_dir/wrangle-vsa-gate-derived.hjson"
    NEW_IDENTITY_LINE="                    identity: \"^https://github\\\\.com/${escaped}@.+\$\"" \
        awk '/^[[:space:]]*identity: "/ { print ENVIRON["NEW_IDENTITY_LINE"]; next } { print }' \
        "$GATE_POLICY" > "$derived"
    if [[ "$(grep -c 'identity: "\^https://github' "$derived")" -ne 1 ]] \
        || grep -q 'build_and_publish_\[a-z\]' "$derived"; then
        die_verify "could not narrow the gate policy identity to $SIGNER_WORKFLOW"
    fi
    printf '%s\n' "$derived"
}

# One ampel call binds subject hash, signature, signer identity, origin
# repository, and the PASSED verdict. Output is buffered and only shown on
# failure so a multi-file run stays readable.
verify_one() {
    local file="$1" vsa="$2" policy="$3"
    local report rc=0
    report="$(mktemp)"
    ampel verify --subject "$file" \
        --policy "$policy" \
        --attestation "$vsa" \
        --context "sourceRepo:https://github.com/${REPO}" \
        > "$report" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        cat "$report" >&2
        rm -f "$report"
        die_verify "ampel rejected $file against $vsa (exit $rc)"
    fi
    rm -f "$report"
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

    local policy
    # Not local: the EXIT trap runs in global scope after main's locals are gone.
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT
    policy="$(wrangle_gate_policy "$tmp_dir")"

    local vsa
    for f in "${files[@]}"; do
        vsa="$VSA_DIR/$(basename "$f").intoto.jsonl"
        [[ -f "$vsa" ]] \
            || die_verify "no VSA found for $f (expected $vsa) — refusing to publish unverified bytes"
        printf 'wrangle/verify-vsa: verifying %s against %s\n' "$f" "$vsa"
        verify_one "$f" "$vsa" "$policy"
    done
    printf 'wrangle/verify-vsa: %d file(s) verified against PASSED VSAs signed for %s\n' \
        "${#files[@]}" "$REPO"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
