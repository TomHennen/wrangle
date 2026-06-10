#!/usr/bin/env bash
# Input-format validation for the verify-vsa action, run as the action's
# first step so a bad input fails before the cosign install and the VSA
# artifact download. verify_vsa.sh sources this and re-runs the same checks
# as its own boundary guard, so the rules live in one place.
#
# Env: ARTIFACT_PATH, REPO, SIGNER_WORKFLOW (see verify_vsa.sh).
set -euo pipefail
set -f

die_input() {
    printf 'wrangle/verify-vsa: %s\n' "$1" >&2
    exit 2
}

validate_inputs() {
    [[ -n "${ARTIFACT_PATH:-}" ]] || die_input "ARTIFACT_PATH is required"
    [[ -e "$ARTIFACT_PATH" ]] || die_input "no such file or directory: $ARTIFACT_PATH"
    [[ "${REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || die_input "REPO must be <owner>/<repo>, got: ${REPO:-<empty>}"
    if [[ -n "${SIGNER_WORKFLOW:-}" ]] \
        && [[ ! "$SIGNER_WORKFLOW" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9._/-]+\.(yml|yaml)$ ]]; then
        die_input "SIGNER_WORKFLOW must be <owner>/<repo>/<path-to-workflow>.yml, got: $SIGNER_WORKFLOW"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    validate_inputs
fi
