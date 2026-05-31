#!/bin/bash
# lib/run_verify.sh — Run the ampel verify + bnd sign steps for actions/verify.
#
# Split into pure arg-builder functions (testable offline against the real
# ampel/bnd CLIs) and thin runners. The runners source env.sh so ampel/bnd are
# found on PATH without writing to $GITHUB_PATH, and route ampel's report
# through wrangle_sanitize_output before it reaches the step summary so a
# crafted policy/attestation cannot inject markup into the GitHub UI.
#
# Inputs arrive as environment variables (already validated by
# validate_verify_inputs.sh): SUBJECT, POLICY, COLLECTOR, FAIL, VSA, and the
# optional CONTEXT, ATTESTATION.
#
# Usage (sourced by the action, or run directly):
#   source "$WRANGLE_ROOT/lib/run_verify.sh"
#   wrangle_verify_emit_vsa   # ampel verify -> unsigned VSA + summary
#   wrangle_sign_vsa          # bnd statement -> signed VSA in place

set -euo pipefail
set -f  # disable globbing — processes external input

WRANGLE_RUN_VERIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build the ampel verify argument vector from the environment. Emitted one
# argument per line so callers (and tests) can read it into an array with
# mapfile and see the exact command shape.
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

# Build the bnd statement argument vector that signs VSA in place.
wrangle_bnd_sign_args() {
    printf '%s\n' statement "$1"
}

wrangle_verify_emit_vsa() {
    # shellcheck source=env.sh
    source "$WRANGLE_RUN_VERIFY_LIB_DIR/env.sh"
    # shellcheck source=sanitize.sh
    source "$WRANGLE_RUN_VERIFY_LIB_DIR/sanitize.sh"

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
    # shellcheck source=env.sh
    source "$WRANGLE_RUN_VERIFY_LIB_DIR/env.sh"

    local args
    mapfile -t args < <(wrangle_bnd_sign_args "$VSA.unsigned")
    mv "$VSA" "$VSA.unsigned"
    bnd "${args[@]}" > "$VSA"
    rm -f "$VSA.unsigned"
}
