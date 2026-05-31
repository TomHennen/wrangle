#!/bin/bash
# actions/verify/run_verify.sh — validate inputs, run `ampel verify`, and
# `bnd`-sign the VSA for actions/verify.
#
# Subcommands (run directly by the action):
#   emit   validate the inputs, then ampel verify -> unsigned VSA + step summary
#   sign   bnd statement -> signed VSA in place
#
# The arg-builder functions stay pure (no side effects) so the unit tests can
# assert the exact ampel/bnd CLI shape offline; `main` runs the work on direct
# execution. Inputs arrive as environment variables: ARTIFACT_NAME, SUBJECT,
# POLICY, COLLECTOR, FAIL, VSA, and the optional CONTEXT, ATTESTATION.

set -euo pipefail
set -f  # disable globbing — processes external input

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$VERIFY_DIR/../../lib" && pwd)"

# Build the ampel verify argument vector from the environment. One argument per
# line so callers (and tests) read it into an array with mapfile.
wrangle_ampel_verify_args() {
    local args=(verify
        --subject="$SUBJECT"
        --collector="$COLLECTOR"
        --policy="$POLICY"
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

wrangle_verify_emit_vsa() {
    # Validate inside the script that does the work — no separate action step.
    # shellcheck source=validate_verify_inputs.sh
    source "$VERIFY_DIR/validate_verify_inputs.sh"
    wrangle_validate_verify_inputs "$ARTIFACT_NAME" "$SUBJECT" "$POLICY" \
        "$COLLECTOR" "$FAIL" "${CONTEXT:-}" "${ATTESTATION:-}"

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

main() {
    case "${1:-}" in
        emit) wrangle_verify_emit_vsa ;;
        sign) wrangle_sign_vsa ;;
        *) printf 'Usage: %s {emit|sign}\n' "${0##*/}" >&2; return 2 ;;
    esac
}

# Run on direct execution; sourcing (the unit tests) exposes the helpers only.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
