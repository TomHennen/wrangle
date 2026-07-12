#!/bin/bash
set -euo pipefail
set -f

_SIGN_METADATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retry.sh
source "$_SIGN_METADATA_DIR/retry.sh"
# shellcheck source=lib/toolbox_run.sh
source "$_SIGN_METADATA_DIR/toolbox_run.sh"

# lib/sign_metadata.sh — Shared build-metadata signing primitives.
#
# Source this to drive `wrangle-attest assemble` — which signs the build metadata
# (SBOM + each scan/<tool>/ manifest it discovers under METADATA_ROOT) for every
# subject and assembles one per-artifact <artifact>.intoto.jsonl bundle
# (provenance + that subject's signed metadata) — and to deliver each signed
# statement to the GitHub attestation store and, for a container, the image's OCI
# referrers. The attest job signs + assembles; the verify job appends the VSA.
#
# Inputs (env): METADATA_ROOT (the metadata dir wrangle-attest reads), SUBJECTS
# (newline-separated dist file paths / sha256: digests, read by
# wrangle_read_subjects), GITHUB_REPOSITORY (store push target), GITHUB_TOKEN
# (bnd reads it to auth the store push), COMMIT (scanned git commit woven into
# the scan/v1 envelope). wrangle-attest keyless-signs via the caller's OIDC identity.

# Build the wrangle-attest arg vector (one arg per line for mapfile) that signs
# every subject's build metadata and assembles the per-artifact bundles. $1 = the
# subjects file; $2 = the provenance source; $3 = the signed-statements output.
# With OCI_TARGET the provenance is the image's raw attestation referrers, which
# the engine filters to the SLSA provenance envelopes.
wrangle_assemble_args() {
    local provenance_flag="--provenance=$2"
    [[ -n "${OCI_TARGET:-}" ]] && provenance_flag="--provenance-referrers=$2"
    printf '%s\n' \
        assemble \
        --metadata-root="${METADATA_ROOT:-}" \
        --subjects-file="$1" \
        "$provenance_flag" \
        --commit="${COMMIT:-}" \
        --sign \
        --bundle-dir="$BUNDLE_OUT" \
        --statements-out="$3"
}

# Build the bnd arg vector that posts a signed statement to the GitHub
# attestation store. $1 is <owner>/<repo>; $2 the signed statement file. The
# store is keyed by subject digest, giving consumers by-digest discovery.
wrangle_bnd_push_args() {
    printf '%s\n' push github "$1" "$2"
}

# Post the signed statement at $1 to the GitHub attestation store. Fails closed:
# a missing by-digest statement is a real delivery gap.
wrangle_push_store() {
    local args
    mapfile -t args < <(wrangle_bnd_push_args "$GITHUB_REPOSITORY" "$1")
    wrangle_retry_once /dev/null wrangle_toolbox_exec \
        --env GITHUB_TOKEN -- bnd "${args[@]}"
}

# Build the cosign arg vector that pushes a single signed statement as an OCI
# referrer. `attach attestation` uploads verbatim (no re-sign), preserving the
# original signer; it accepts only one bundle line. $1 is the single-statement
# file, $2 the image digest ref.
wrangle_cosign_attach_args() {
    printf '%s\n' attach attestation \
        --attestation "$1" \
        "$2"
}

# Push the signed statement at $1 as its own OCI referrer on OCI_TARGET. No-op
# without OCI_TARGET (go/npm/python deliver via the store only). Fails closed:
# a missing by-digest referrer is a real delivery gap.
wrangle_push_oci_referrer() {
    [[ -z "${OCI_TARGET:-}" ]] && return 0
    local args
    mapfile -t args < <(wrangle_cosign_attach_args "$1" "$OCI_TARGET")
    wrangle_retry_once /dev/null wrangle_toolbox_exec \
        --docker-config --env GITHUB_TOKEN -- cosign "${args[@]}"
}

# Build the cosign arg vector that downloads an image's attestation referrers as
# newline-delimited DSSE envelopes. $1 is the image digest ref.
wrangle_cosign_download_args() {
    printf '%s\n' download attestation "$1"
}

# Write the provenance source to $1, once per run: the image's raw
# attestation referrers (container, when OCI_TARGET is set — the engine filters
# them to the SLSA provenance envelopes) or BUNDLE_IN (go/npm/python). Fails
# closed on a missing provenance.
wrangle_stage_provenance() {
    local provenance="$1"
    if [[ -n "${OCI_TARGET:-}" ]]; then
        local args
        mapfile -t args < <(wrangle_cosign_download_args "$OCI_TARGET")
        # Retry once like the toolbox's sibling downloads above: a transient
        # blip on the provenance download must not fail the whole attest job.
        wrangle_retry_once "$provenance" wrangle_toolbox_exec --docker-config --env GITHUB_TOKEN -- cosign "${args[@]}"
    else
        [[ -s "$BUNDLE_IN" ]] || { printf 'wrangle: provenance %s missing or empty\n' "${BUNDLE_IN:-}" >&2; return 1; }
        cp "$BUNDLE_IN" "$provenance"
    fi
}

# Map a subject (dist path or algo:hex digest) to its bundle filename: basename
# with the digest's colon replaced.
wrangle_bundle_name() {
    local base="${1##*/}"
    printf '%s.intoto.jsonl\n' "${base//:/-}"
}

# Sign every subject's build-metadata in the attest job and assemble one
# per-artifact <artifact>.intoto.jsonl bundle into BUNDLE_OUT: the shared
# provenance plus that subject's signed SBOM + scan/v1 lines. Each signed
# line is then posted to the GitHub attestation store, and with OCI_TARGET set
# (container) additionally pushed as its own by-digest OCI referrer. Persisted
# independent of the policy verdict; the VSA stays in verify. wrangle-attest
# assemble fails closed on a missing metadata dir, an empty subject set, an
# unreadable provenance, a duplicate bundle basename, or a subject that
# yields no signed statement (the release SBOM is always present). Inputs (env):
# METADATA_ROOT, SUBJECTS, GITHUB_REPOSITORY, GITHUB_TOKEN, COMMIT, BUNDLE_OUT,
# one of BUNDLE_IN / OCI_TARGET (the provenance source).
wrangle_sign_and_assemble_bundles() {
    local provenance subjects_file stmts rc=0
    provenance="$(mktemp "${RUNNER_TEMP:-/tmp}/provenance.XXXXXX")"
    subjects_file="$(mktemp "${RUNNER_TEMP:-/tmp}/subjects.XXXXXX")"
    stmts="$(mktemp "${RUNNER_TEMP:-/tmp}/attestmeta.XXXXXX")"
    printf '%s\n' "$SUBJECTS" > "$subjects_file"

    local args line
    if wrangle_stage_provenance "$provenance"; then
        mapfile -t args < <(wrangle_assemble_args "$subjects_file" "$provenance" "$stmts")
        wrangle_retry_once /dev/null wrangle_toolbox_exec \
            --sigstore -- wrangle-attest "${args[@]}" || rc=$?
    else
        rc=$?
    fi

    if [[ "$rc" -eq 0 ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf '%s\n' "$line" > "$stmts.line"
            wrangle_push_store "$stmts.line"
            wrangle_push_oci_referrer "$stmts.line"
        done < "$stmts"
    fi
    rm -f "$stmts" "$stmts.line" "$provenance" "$subjects_file"
    return "$rc"
}

# Split SUBJECTS into WRANGLE_SUBJECTS, dropping blank lines. Fail closed on an
# empty set: a release subject is always present, so zero means a wiring bug.
wrangle_read_subjects() {
    mapfile -t WRANGLE_SUBJECTS <<< "$SUBJECTS"
    local s kept=()
    for s in "${WRANGLE_SUBJECTS[@]}"; do
        [[ "$s" =~ ^[[:space:]]*$ ]] || kept+=("$s")
    done
    WRANGLE_SUBJECTS=("${kept[@]}")
    if [[ "${#WRANGLE_SUBJECTS[@]}" -eq 0 ]]; then
        printf 'wrangle: no subjects to sign — refusing to proceed\n' >&2
        return 1
    fi
}
