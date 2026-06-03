#!/bin/bash
# actions/verify/run_verify.sh — validate inputs, run `ampel verify`, and
# `bnd`-sign the VSA for actions/verify.
#
# Subcommands (run directly by the action):
#   emit   validate the inputs, then ampel verify -> unsigned VSA + step summary
#   sign   bnd statement -> signed VSA in place
#   push   cosign attach attestation -> push signed VSA as an OCI referrer
#
# The arg-builder functions stay pure (no side effects) so the unit tests can
# assert the exact ampel/bnd/cosign CLI shape offline; `main` runs the work on
# direct execution. Inputs arrive as environment variables: ARTIFACT_NAME,
# SUBJECT, POLICY, COLLECTOR, FAIL, VSA, and the optional CONTEXT, ATTESTATION,
# OCI_TARGET (when set, the signed VSA is pushed to that registry digest).

set -euo pipefail
set -f  # disable globbing — processes external input

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$VERIFY_DIR/../../lib" && pwd)"
REPO_ROOT="$(cd "$VERIFY_DIR/../.." && pwd)"

# Resolve a relative policy path against the action's own checkout: the wrangle
# PolicySets ship with this action, not in the caller's workspace, and ampel
# would otherwise resolve a bare "policies/..." against the caller's CWD.
# Absolute paths and ampel locators (git+https://…, oci:…, anything with ://)
# pass through unchanged.
wrangle_resolve_policy() {
    case "$1" in
        /*|*://*) printf '%s\n' "$1" ;;
        *)        printf '%s\n' "$REPO_ROOT/$1" ;;
    esac
}

# Build the ampel verify argument vector from the environment. One argument per
# line so callers (and tests) read it into an array with mapfile.
wrangle_ampel_verify_args() {
    local args=(verify
        --subject="$SUBJECT"
        --collector="$COLLECTOR"
        --policy="$(wrangle_resolve_policy "$POLICY")"
        --exit-code="$FAIL"
        --attest-results
        --attest-format=vsa
        --results-path="$VSA")
    [[ -n "${CONTEXT:-}" ]] && args+=(--context "$CONTEXT")
    [[ -n "${ATTESTATION:-}" ]] && args+=(--attestation "$ATTESTATION")
    args+=(--format=html)
    printf '%s\n' "${args[@]}"
}

# Build the bnd statement argument vector that signs the VSA in place.
wrangle_bnd_sign_args() {
    printf '%s\n' statement "$1"
}

# Build the cosign argument vector that pushes the already-signed VSA bundle as
# an OCI referrer on the image digest. `attach attestation` uploads the bundle
# verbatim — it does NOT re-sign (unlike `cosign attest`), so the bnd-minted
# signer identity is preserved. $1 is the VSA file, $2 the image digest ref.
wrangle_cosign_attach_args() {
    printf '%s\n' attach attestation \
        --attestation "$1" \
        "$2"
}

wrangle_verify_emit_vsa() {
    # Validate inside the script that does the work — no separate action step.
    # shellcheck source=validate_verify_inputs.sh
    source "$VERIFY_DIR/validate_verify_inputs.sh"
    # shellcheck disable=SC2153 # env-var inputs; the sourced validate script's lowercase locals trip the misspelling heuristic
    wrangle_validate_verify_inputs "$ARTIFACT_NAME" "$SUBJECT" "$POLICY" \
        "$COLLECTOR" "$FAIL" "${CONTEXT:-}" "${ATTESTATION:-}" "${OCI_TARGET:-}"

    # shellcheck source=../../lib/env.sh
    source "$LIB_DIR/env.sh"
    # shellcheck source=../../lib/sanitize.sh
    source "$LIB_DIR/sanitize.sh"

    local args report rc=0
    mapfile -t args < <(wrangle_ampel_verify_args)

    # ampel's --exit-code carries the policy verdict, so it must reach the
    # caller untouched. Capture the report to a file first; piping ampel
    # straight into the truncating sanitizer would let a >MAX_SUMMARY report
    # SIGPIPE the pipeline and flip a PASS into a blocked release.
    report="$(mktemp)"
    ampel "${args[@]}" > "$report" || rc=$?
    wrangle_sanitize_output < "$report" >> "$GITHUB_STEP_SUMMARY"
    rm -f "$report"
    return "$rc"
}

wrangle_sign_vsa() {
    # shellcheck source=../../lib/env.sh
    source "$LIB_DIR/env.sh"

    local args
    mapfile -t args < <(wrangle_bnd_sign_args "$VSA.unsigned")
    mv "$VSA" "$VSA.unsigned"
    bnd "${args[@]}" > "$VSA"
    rm -f "$VSA.unsigned"
}

wrangle_push_vsa() {
    # No OCI target => npm/go/python path: the VSA lives only in the workflow
    # artifact (and, for those types, the release asset). Nothing to push.
    [[ -z "${OCI_TARGET:-}" ]] && return 0

    # shellcheck source=../../lib/env.sh
    source "$LIB_DIR/env.sh"

    local args
    mapfile -t args < <(wrangle_cosign_attach_args "$VSA" "$OCI_TARGET")
    # Under set -e a push failure fails the step (fail-closed): a VSA a consumer
    # can't fetch by digest is a silent gap, indistinguishable from never having
    # produced one.
    cosign "${args[@]}"
}

main() {
    case "${1:-}" in
        # `run` does emit then sign then push in one process so the unsigned VSA
        # never lives on disk across a step boundary. emit/sign/push stay
        # callable for tests.
        run)  wrangle_verify_emit_vsa; wrangle_sign_vsa; wrangle_push_vsa ;;
        emit) wrangle_verify_emit_vsa ;;
        sign) wrangle_sign_vsa ;;
        push) wrangle_push_vsa ;;
        *) printf 'Usage: %s {run|emit|sign|push}\n' "${0##*/}" >&2; return 2 ;;
    esac
}

# Run on direct execution; sourcing (the unit tests) exposes the helpers only.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
