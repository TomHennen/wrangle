#!/bin/bash
# Sign every build-metadata attestation (SBOM + each scan/<tool>/ manifest
# wrangle-attest discovers under METADATA_ROOT) for each dist subject and post
# each signed statement to the GitHub attestation store. Runs in the attest job
# so the signed metadata is persisted independent of the later policy verdict.
# The VSA is NOT produced here — it is a verdict ampel mints in verify.
#
# Each subject is self-digested via wrangle-attest --artifact, binding the SAME
# sha256 digest verify binds the VSA to. bnd keyless-signs via the calling
# workflow's OIDC identity (id-token: write) and the store push authenticates
# with GITHUB_TOKEN (attestations: write).
#
# Inputs (env): METADATA_ROOT (the metadata dir holding the manifests), SUBJECTS
# (newline-separated dist file paths), GITHUB_REPOSITORY (store push target),
# GITHUB_TOKEN (bnd store auth), OUT (signed-metadata JSONL to emit), and
# optional COMMIT (scanned git commit woven into the scan/v1 envelope).

set -euo pipefail
set -f  # disable globbing — processes external input

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"

# Re-evaluation is deterministic, so a retry can only flip a transient Sigstore
# or store I/O failure. WRANGLE_RETRY_DELAY spaces attempts (tests set it to 0).
wrangle_retry_once() {
    local out="$1"; shift
    "$@" > "$out" && return 0
    local rc=$?
    printf 'wrangle: %s failed (exit %s); retrying once for transient I/O\n' "$1" "$rc" >&2
    sleep "${WRANGLE_RETRY_DELAY:-5}"
    "$@" > "$out"
}

# Build the wrangle-attest arg vector (one arg per line for mapfile) that signs
# the build metadata for one subject into a JSONL bundle. $1 = subject file
# self-digested into the sha256 subject; $2 = output JSONL path.
wrangle_attest_args() {
    printf '%s\n' \
        --metadata-root="$METADATA_ROOT" \
        --artifact="$1" \
        --commit="${COMMIT:-}" \
        --sign \
        --out="$2"
}

# Build the bnd arg vector that posts a signed statement to the GitHub
# attestation store. $1 is <owner>/<repo>; $2 the signed statement file. The
# store is keyed by subject digest, giving consumers by-digest discovery.
wrangle_bnd_push_args() {
    printf '%s\n' push github "$1" "$2"
}

# Sign subject $1's build-metadata statements into the JSONL at $2, one signed
# bundle per line; leaves $2 empty when there is no metadata. Fails closed.
wrangle_sign_metadata_statements() {
    local subject="$1" stmts="$2"
    local args
    mapfile -t args < <(wrangle_attest_args "$subject" "$stmts")
    wrangle_retry_once /dev/null wrangle-attest "${args[@]}"
}

# Post the signed statement at $1 to the GitHub attestation store. Fails closed.
wrangle_push_store() {
    local args
    mapfile -t args < <(wrangle_bnd_push_args "$GITHUB_REPOSITORY" "$1")
    wrangle_retry_once /dev/null bnd "${args[@]}"
}

# Read SUBJECTS into WRANGLE_SUBJECTS, dropping blank lines. Fail closed on an
# empty set: a release subject is always present, so zero means a wiring bug.
wrangle_read_subjects() {
    mapfile -t WRANGLE_SUBJECTS <<< "$SUBJECTS"
    local s kept=()
    for s in "${WRANGLE_SUBJECTS[@]}"; do
        [[ "$s" =~ ^[[:space:]]*$ ]] || kept+=("$s")
    done
    WRANGLE_SUBJECTS=("${kept[@]}")
    if [[ "${#WRANGLE_SUBJECTS[@]}" -eq 0 ]]; then
        printf 'wrangle: no subjects to sign metadata for\n' >&2
        return 1
    fi
}

# Sign and push the metadata for every subject, accumulating every signed line
# into OUT (the emitted signed-metadata artifact).
wrangle_sign_metadata() {
    # shellcheck source=../../lib/env.sh
    source "$LIB_DIR/env.sh"

    if [[ -z "${METADATA_ROOT:-}" || ! -d "${METADATA_ROOT}" ]]; then
        printf 'wrangle: metadata dir %s missing — nothing to sign\n' "${METADATA_ROOT:-}" >&2
        return 1
    fi

    local -a WRANGLE_SUBJECTS
    wrangle_read_subjects

    : > "$OUT"
    local stmts subject line
    stmts="$(mktemp "${RUNNER_TEMP:-/tmp}/attestmeta.XXXXXX")"
    for subject in "${WRANGLE_SUBJECTS[@]}"; do
        : > "$stmts"
        wrangle_sign_metadata_statements "$subject" "$stmts"
        # A subject with no discovered manifests would yield an empty file; the
        # release SBOM manifest is always present, so an empty file is a bug.
        if [[ ! -s "$stmts" ]]; then
            printf 'wrangle: no signed metadata produced for %s\n' "$subject" >&2
            rm -f "$stmts"
            return 1
        fi
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf '%s\n' "$line" >> "$OUT"
            printf '%s\n' "$line" > "$stmts.line"
            wrangle_push_store "$stmts.line"
        done < "$stmts"
        rm -f "$stmts.line"
    done
    rm -f "$stmts"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    wrangle_sign_metadata
fi
