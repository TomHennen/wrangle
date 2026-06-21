#!/bin/bash
set -euo pipefail
set -f

# Sign every build-metadata attestation (SBOM + each scan/<tool>/ manifest
# wrangle-attest discovers under METADATA_ROOT) for each dist subject and post
# each signed statement to the GitHub attestation store. Runs in the attest job
# so the signed metadata is persisted independent of the later policy verdict.
# The VSA is NOT produced here — it is a verdict ampel mints in verify.
#
# The signing primitives are shared with the verify job (lib/sign_metadata.sh).
# Inputs (env): METADATA_ROOT, SUBJECTS, GITHUB_REPOSITORY, GITHUB_TOKEN, COMMIT
# (see lib/sign_metadata.sh), plus OUT (the signed-metadata JSONL to emit).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
# shellcheck source=../../lib/sign_metadata.sh
source "$LIB_DIR/sign_metadata.sh"

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
        # The release SBOM manifest is always present, so an empty file is a bug.
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
