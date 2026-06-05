#!/bin/bash
# actions/verify_attestation/validate_verify_attestation_inputs.sh — validate
# the inputs to actions/verify_attestation before they reach `gh attestation
# verify`.
#
# Every value flows onto a command line, so the allowlists reject any character
# that could let an input break out of the run: step. The classes are
# per-input: subject is a path or an oci:// URI, signer-workflow is an
# owner/repo/path locator, repo is owner/repo, bundle-path is a file path, and
# predicate-type is a URL.
#
# Usage (source then call, or run directly with the same arg order):
#   source "$DIR/validate_verify_attestation_inputs.sh"
#   wrangle_validate_verify_attestation_inputs SUBJECT REPO SIGNER_WORKFLOW \
#       BUNDLE_PATH PREDICATE_TYPE CHECKSUMS_PATH

set -euo pipefail
set -f  # disable globbing — processes external input

wrangle_validate_verify_attestation_inputs() {
    if [[ $# -ne 6 ]]; then
        printf 'Usage: wrangle_validate_verify_attestation_inputs SUBJECT REPO SIGNER_WORKFLOW BUNDLE_PATH PREDICATE_TYPE CHECKSUMS_PATH\n' >&2
        return 1
    fi

    local subj="$1" repo="$2" signer_workflow="$3"
    local bundle_path="$4" predicate_type="$5" checksums_path="$6"

    # Each failed check returns immediately so the first invalid input — not the
    # last — is what aborts the action.
    _wrangle_reject() {
        printf 'wrangle: invalid %s "%s" — %s\n' "$1" "$2" "$3" >&2
        return 1
    }

    # subject is either an oci://<image>@sha256:<digest> ref or a path (file or
    # directory) the runner produced; reject traversal explicitly since the
    # charset admits dots. A leading dash would be parsed as a flag by gh
    # (the subject is a trailing positional), so reject it outright — the
    # `-- ` end-of-options guard in verify_attestation.sh is the second line.
    [[ "$subj" != -* ]] || { _wrangle_reject subject "$subj" 'must not start with a dash'; return 1; }
    [[ "$subj" != *..* ]] || { _wrangle_reject subject "$subj" 'path traversal'; return 1; }
    [[ "$subj" =~ ^[A-Za-z0-9._:/@+-]+$ ]] || { _wrangle_reject subject "$subj" 'disallowed characters'; return 1; }
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { _wrangle_reject repo "$repo" 'must be owner/repo'; return 1; }
    # signer-workflow is gh's [host/]owner/repo/path-to-workflow form (no @ref).
    [[ "$signer_workflow" =~ ^[A-Za-z0-9._/-]+\.(yml|yaml)$ ]] || { _wrangle_reject signer-workflow "$signer_workflow" 'must be owner/repo/.github/workflows/<file>.yml'; return 1; }
    [[ -z "$bundle_path" || ( "$bundle_path" != *..* && "$bundle_path" =~ ^[A-Za-z0-9._/-]+$ ) ]] || { _wrangle_reject bundle-path "$bundle_path" 'disallowed characters or traversal'; return 1; }
    [[ "$predicate_type" =~ ^https://[A-Za-z0-9._/-]+$ ]] || { _wrangle_reject predicate-type "$predicate_type" 'must be an https:// URL'; return 1; }
    [[ -z "$checksums_path" || ( "$checksums_path" != *..* && "$checksums_path" =~ ^[A-Za-z0-9._/-]+$ ) ]] || { _wrangle_reject checksums-path "$checksums_path" 'disallowed characters or traversal'; return 1; }
}

# Allow direct execution for CI/manual use; sourcing is the action's path.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    wrangle_validate_verify_attestation_inputs "$@"
fi
