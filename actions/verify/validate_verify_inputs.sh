#!/bin/bash
# actions/verify/validate_verify_inputs.sh — Validate actions/verify inputs
# before they reach ampel/bnd.
#
# Every value flows into a shell command line, so the allowlist rejects any
# character that could let an input break out of the run: step. The character
# classes are deliberately per-input: artifact-name becomes a filename, while
# subject/policy/collector/context/attestation are ampel locators with their
# own legal punctuation.
#
# Usage (source then call, or run directly with the same arg order):
#   source "$VERIFY_DIR/validate_verify_inputs.sh"
#   wrangle_validate_verify_inputs ARTIFACT_NAME SUBJECT POLICY COLLECTOR \
#       FAIL CONTEXT ATTESTATION OCI_TARGET

set -euo pipefail
set -f  # disable globbing — processes external input

wrangle_validate_verify_inputs() {
    if [[ $# -ne 8 ]]; then
        printf 'Usage: wrangle_validate_verify_inputs ARTIFACT_NAME SUBJECT POLICY COLLECTOR FAIL CONTEXT ATTESTATION OCI_TARGET\n' >&2
        return 1
    fi

    local artifact_name="$1" subject="$2" policy="$3" collector="$4"
    local fail="$5" context="$6" attestation="$7" oci_target="$8"

    # Each failed check returns immediately so the first invalid input — not the
    # last — is what aborts the action.
    _wrangle_reject() {
        printf 'wrangle: invalid %s "%s" — %s\n' "$1" "$2" "$3" >&2
        return 1
    }

    [[ "$artifact_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || { _wrangle_reject artifact-name "$artifact_name" 'must match ^[A-Za-z0-9][A-Za-z0-9._-]*$'; return 1; }
    [[ "$subject"   =~ ^[A-Za-z0-9._:/@+-]+$   ]] || { _wrangle_reject subject   "$subject"   'disallowed characters'; return 1; }
    [[ "$policy"    =~ ^[A-Za-z0-9._:/@#+-]+$  ]] || { _wrangle_reject policy    "$policy"    'disallowed characters'; return 1; }
    [[ "$collector" =~ ^[A-Za-z0-9._:/@#+,-]+$ ]] || { _wrangle_reject collector "$collector" 'disallowed characters'; return 1; }
    [[ "$fail"      =~ ^(true|false)$          ]] || { _wrangle_reject fail      "$fail"      'must be "true" or "false"'; return 1; }
    [[ -z "$context"     || "$context"     =~ ^[A-Za-z0-9._:/@#+,%=-]+$ ]] || { _wrangle_reject context     "$context"     'disallowed characters'; return 1; }
    [[ -z "$attestation" || "$attestation" =~ ^[A-Za-z0-9._:/@#+,-]+$   ]] || { _wrangle_reject attestation "$attestation" 'disallowed characters'; return 1; }
    # oci-target becomes an argument to a registry-write command, so it must be
    # digest-pinned (never a mutable tag) — an optional :tag is tolerated only
    # when followed by the immutable @sha256: digest. Empty is allowed. The `.`
    # the charset permits (registry hostnames, image-path dots) would also admit
    # a `..` segment, so reject that explicitly before the shape check.
    if [[ -n "$oci_target" ]]; then
        [[ "$oci_target" != *..* ]] || { _wrangle_reject oci-target "$oci_target" 'path traversal'; return 1; }
        [[ "$oci_target" =~ ^[a-z0-9][a-z0-9._/-]*(:[a-zA-Z0-9._-]+)?@sha256:[a-f0-9]{64}$ ]] || { _wrangle_reject oci-target "$oci_target" 'must be a digest-pinned OCI ref (…@sha256:<64 hex>)'; return 1; }
    fi
}

# Allow direct execution for CI/manual use; sourcing is the action's path.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    wrangle_validate_verify_inputs "$@"
fi
