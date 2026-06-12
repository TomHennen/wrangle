#!/usr/bin/env bash
# Input-format validation for the verify-vsa action, run as the action's
# first step so a bad input fails before the tool install and the VSA
# artifact download. verify_vsa.sh sources this and re-runs the same checks
# as its own boundary guard, so the rules live in one place.
#
# Env: ARTIFACT_PATH, RESOURCE_URI, REPO (see verify_vsa.sh).
set -euo pipefail
set -f

die_input() {
    printf 'wrangle/verify-vsa: %s\n' "$1" >&2
    exit 2
}

validate_inputs() {
    [[ -n "${ARTIFACT_PATH:-}" ]] || die_input "ARTIFACT_PATH is required"
    [[ -e "$ARTIFACT_PATH" ]] || die_input "no such file or directory: $ARTIFACT_PATH"
    # Both reach ampel as a single --context value. The charset excludes the
    # comma (and whitespace) on purpose: ampel splits --context on commas, so
    # a comma in either could smuggle a second context pair and override the
    # sourceRepo binding. Mirrors actions/verify's single-value locator
    # allowlist.
    [[ -n "${RESOURCE_URI:-}" ]] || die_input "RESOURCE_URI is required"
    [[ "$RESOURCE_URI" =~ ^[A-Za-z0-9._:/@+-]+$ ]] \
        || die_input "RESOURCE_URI has disallowed characters: $RESOURCE_URI"
    [[ "${REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || die_input "REPO must be <owner>/<repo>, got: ${REPO:-<empty>}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    validate_inputs
fi
