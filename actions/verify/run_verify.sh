#!/bin/bash
# actions/verify/run_verify.sh — validate inputs, run `ampel verify` per dist
# subject, `bnd`-sign each VSA, and append every signed VSA to the provenance
# bundle to produce one `.intoto.jsonl` consumers fetch.
#
# Subcommands (run directly by the action):
#   run    emit -> sign -> append for every subject in one process, then push
#          (container) — so an unsigned VSA never lives on disk across a step
#          boundary; the output bundle = provenance lines + one signed VSA line
#          per subject.
#   attach upload the bundle to the GitHub release for the current tag, if any.
#
# The arg-builder functions stay pure (no side effects) so the unit tests can
# assert the exact ampel/bnd/cosign CLI shape offline; `main` runs the work on
# direct execution. Inputs arrive as environment variables: SUBJECTS (newline-
# separated dist subjects), POLICY, COLLECTOR, FAIL, CONTEXT, BUNDLE_IN (the
# provenance JSONL the VSAs append to), BUNDLE_OUT (the emitted bundle), plus
# the optional ATTESTATION, OCI_TARGET (when set, the bundle is fetched from and
# pushed back to that registry digest as one referrer).

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

# Run a command and, on failure, run it once more. Sigstore I/O inside ampel
# and bnd fails intermittently (an identity check on one tenet, the DSSE
# signing stream) on runs that pass identically seconds later; re-evaluating
# the same attestations against the same policy is deterministic, so a retry
# can only flip a transient failure, never a real verdict. $1 is the stdout
# capture file, truncated per attempt so a retry can't append to a partial
# report. WRANGLE_RETRY_DELAY (seconds) spaces the attempts so a brief
# Sigstore blip has time to clear; an immediate retry tends to hit the same
# failing connection. Tests set it to 0.
wrangle_retry_once() {
    local out="$1"; shift
    "$@" > "$out" && return 0
    local rc=$?
    printf 'wrangle: %s failed (exit %s); retrying once for transient Sigstore I/O\n' "$1" "$rc" >&2
    sleep "${WRANGLE_RETRY_DELAY:-5}"
    "$@" > "$out"
}

# Build the ampel verify argument vector for one subject. One argument per line
# so callers (and tests) read it into an array with mapfile. $1 is the subject
# to bind the VSA to; $2 the path ampel writes the unsigned VSA to.
wrangle_ampel_verify_args() {
    local subject="$1" results_path="$2"
    local args=(verify
        --subject="$subject"
        --collector="$COLLECTOR"
        --policy="$(wrangle_resolve_policy "$POLICY")"
        --exit-code="$FAIL"
        --attest-results
        --attest-format=vsa
        --results-path="$results_path")
    [[ -n "${CONTEXT:-}" ]] && args+=(--context "$CONTEXT")
    [[ -n "${ATTESTATION:-}" ]] && args+=(--attestation "$ATTESTATION")
    args+=(--format=html)
    printf '%s\n' "${args[@]}"
}

# Build the bnd statement argument vector that signs a VSA in place.
wrangle_bnd_sign_args() {
    printf '%s\n' statement "$1"
}

# Build the cosign argument vector that downloads the image's existing
# attestation referrers (the signed provenance) as newline-delimited DSSE
# envelopes — the JSONL bundle the VSAs append to. $1 is the image digest ref.
wrangle_cosign_download_args() {
    printf '%s\n' download attestation "$1"
}

# Build the cosign argument vector that pushes the bundle as ONE OCI referrer on
# the image digest. `attach attestation` uploads the bundle verbatim — it does
# NOT re-sign (unlike `cosign attest`), so the provenance + bnd-minted signers
# are preserved. $1 is the bundle file, $2 the image digest ref.
wrangle_cosign_attach_args() {
    printf '%s\n' attach attestation \
        --attestation "$1" \
        "$2"
}

# Split the newline-separated SUBJECTS env into an array. Fail closed on an
# empty set: zero subjects would emit a provenance-only bundle with no VSA,
# silently dropping the release-gating verification.
wrangle_read_subjects() {
    mapfile -t WRANGLE_SUBJECTS <<< "$SUBJECTS"
    local s kept=()
    for s in "${WRANGLE_SUBJECTS[@]}"; do
        # Drop blank/whitespace-only lines (trailing newline of the heredoc,
        # stray indentation) so they don't become bogus subjects.
        [[ "$s" =~ ^[[:space:]]*$ ]] || kept+=("$s")
    done
    WRANGLE_SUBJECTS=("${kept[@]}")
    if [[ "${#WRANGLE_SUBJECTS[@]}" -eq 0 ]]; then
        printf 'wrangle: no subjects to verify — refusing to emit a VSA-less bundle\n' >&2
        return 1
    fi
}

# ampel verify one subject -> unsigned VSA, streaming the HTML report to the
# step summary. $1 is the subject, $2 the unsigned-VSA path. Mirrors the
# single-process emit the signed-VSA guarantee depends on.
wrangle_verify_emit_vsa() {
    local subject="$1" results_path="$2"
    local args report rc=0
    mapfile -t args < <(wrangle_ampel_verify_args "$subject" "$results_path")

    # ampel's --exit-code carries the policy verdict, so it must reach the
    # caller untouched. Capture the report to a file first; piping ampel
    # straight into the truncating sanitizer would let a >MAX_SUMMARY report
    # SIGPIPE the pipeline and flip a PASS into a blocked release.
    report="$(mktemp)"
    wrangle_retry_once "$report" ampel "${args[@]}" || rc=$?
    wrangle_sanitize_output < "$report" >> "$GITHUB_STEP_SUMMARY"
    # On a FAILED verdict the report (which tenet failed, missing attestation,
    # etc.) is the operator's only signal for why the release was blocked, and
    # the step summary is easy to miss — echo it to the job log too.
    if [[ "$rc" -ne 0 ]]; then
        printf 'wrangle: ampel verification failed for %s (exit %s):\n' "$subject" "$rc" >&2
        cat "$report" >&2
    fi
    rm -f "$report"
    return "$rc"
}

# bnd-sign the unsigned VSA at $1 in place; the signed statement lands at $1.
wrangle_sign_vsa() {
    local vsa="$1"
    local args
    mapfile -t args < <(wrangle_bnd_sign_args "$vsa.unsigned")
    mv "$vsa" "$vsa.unsigned"
    wrangle_retry_once "$vsa" bnd "${args[@]}"
    rm -f "$vsa.unsigned"
}

# Seed BUNDLE_OUT with the provenance lines. For container the provenance lives
# as an OCI referrer and is fetched with cosign; otherwise BUNDLE_IN is the
# provenance JSONL the attest job staged. Copying keeps BUNDLE_IN intact so a
# re-run starts from the same base.
wrangle_seed_bundle() {
    if [[ -n "${OCI_TARGET:-}" ]]; then
        local args
        mapfile -t args < <(wrangle_cosign_download_args "$OCI_TARGET")
        cosign "${args[@]}" > "$BUNDLE_OUT"
    else
        cp "$BUNDLE_IN" "$BUNDLE_OUT"
    fi
}

# Append the bundle to the registry as one referrer (container only). Under
# set -e a push failure fails the step (fail-closed): a bundle a consumer can't
# fetch by digest is a silent gap, indistinguishable from never producing one.
wrangle_push_bundle() {
    [[ -z "${OCI_TARGET:-}" ]] && return 0
    local args
    mapfile -t args < <(wrangle_cosign_attach_args "$BUNDLE_OUT" "$OCI_TARGET")
    cosign "${args[@]}"
}

# Verify every subject, sign each VSA, and append it to BUNDLE_OUT — all in one
# process so an unsigned VSA never crosses a step boundary. The unsigned VSA and
# the signed-then-appended line stay in $RUNNER_TEMP, never a persisted artifact.
wrangle_run() {
    # Validate inside the script that does the work — no separate action step.
    # shellcheck source=validate_verify_inputs.sh
    source "$VERIFY_DIR/validate_verify_inputs.sh"

    # shellcheck source=../../lib/env.sh
    source "$LIB_DIR/env.sh"
    # shellcheck source=../../lib/sanitize.sh
    source "$LIB_DIR/sanitize.sh"

    local -a WRANGLE_SUBJECTS
    wrangle_read_subjects

    # One subject's value validates the same way for every subject; the rest of
    # the inputs are shared, so validate them once against the first subject.
    # shellcheck disable=SC2153 # env-var inputs; the sourced validate script's lowercase locals trip the misspelling heuristic
    local subject
    for subject in "${WRANGLE_SUBJECTS[@]}"; do
        wrangle_validate_verify_inputs "vsa.intoto.jsonl" "$subject" "$POLICY" \
            "$COLLECTOR" "$FAIL" "${CONTEXT:-}" "${ATTESTATION:-}" "${OCI_TARGET:-}"
    done

    wrangle_seed_bundle

    local tmp_vsa
    tmp_vsa="$(mktemp "${RUNNER_TEMP:-/tmp}/vsa.XXXXXX")"
    for subject in "${WRANGLE_SUBJECTS[@]}"; do
        wrangle_verify_emit_vsa "$subject" "$tmp_vsa"
        wrangle_sign_vsa "$tmp_vsa"
        # bnd emits a multi-line pretty statement; jq -c flattens it to the one
        # JSON-object-per-line a JSONL bundle requires.
        jq -c . "$tmp_vsa" >> "$BUNDLE_OUT"
    done
    rm -f "$tmp_vsa"

    wrangle_push_bundle
}

# Attach the bundle to the GitHub release for the current tag, IF one exists.
# wrangle does not create releases — the adopter's release tooling owns that; on
# a tag with no release the bundle remains available as the workflow artifact.
wrangle_attach_release() {
    local ref="$GITHUB_REF_NAME"
    if gh release view "$ref" >/dev/null 2>&1; then
        gh release upload "$ref" "$BUNDLE_OUT" --clobber
    else
        printf 'wrangle: no GitHub release for %s; the bundle is the workflow artifact only.\n' "$ref" >&2
    fi
}

main() {
    case "${1:-}" in
        run)    wrangle_run ;;
        attach) wrangle_attach_release ;;
        *) printf 'Usage: %s {run|attach}\n' "${0##*/}" >&2; return 2 ;;
    esac
}

# Run on direct execution; sourcing (the unit tests) exposes the helpers only.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
