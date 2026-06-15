#!/bin/bash
# actions/verify/run_verify.sh — validate inputs, run `ampel verify` per dist
# subject, `bnd`-sign each VSA, and produce one per-artifact `.intoto.jsonl`
# bundle per subject (provenance lines + that subject's signed VSA) consumers
# fetch.
#
# Subcommands (run directly by the action):
#   run    emit -> sign -> append for every subject in one process, then push
#          each bundle to the registry best-effort (container) — so an unsigned
#          VSA never lives on disk across a step boundary. Each subject yields
#          its own <artifact>.intoto.jsonl = the provenance lines plus that one
#          subject's signed VSA line.
#   attach upload every per-artifact bundle to the GitHub release for the
#          current tag, if any.
#
# The arg-builder functions stay pure (no side effects) so the unit tests can
# assert the exact ampel/bnd/cosign CLI shape offline; `main` runs the work on
# direct execution. Inputs arrive as environment variables: SUBJECTS (newline-
# separated dist subjects), POLICY, COLLECTOR, FAIL, CONTEXT, BUNDLE_IN (the
# provenance JSONL the VSAs append to), BUNDLE_OUT (the directory the
# per-artifact bundles are written into), plus the optional ATTESTATION,
# OCI_TARGET (when set, the provenance seed is fetched from that registry digest
# and each per-artifact bundle is pushed back as its own referrer best-effort —
# the workflow-artifact upload is the guaranteed delivery).

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

# Build the cosign argument vector that pushes a per-artifact bundle as an OCI
# referrer on the image digest. `attach attestation` uploads the bundle verbatim
# — it does NOT re-sign (unlike `cosign attest`), so the provenance + bnd-minted
# signers are preserved. $1 is the bundle file, $2 the image digest ref.
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

# Predicate type of the SLSA provenance statements each bundle seeds from. A
# verify re-run against the same image digest re-downloads every referrer —
# including the VSAs this action pushed last time — so the seed filters to just
# this type, dropping any prior VSA/bundle lines. That keeps the round-trip
# idempotent: each run rebuilds the same one-provenance + VSA bundle instead of
# accumulating duplicate provenance and stale VSA lines.
WRANGLE_PROVENANCE_PREDICATE="https://slsa.dev/provenance/v1"

# Write the shared provenance seed to $1. For container the provenance lives as
# an OCI referrer and is fetched with cosign; otherwise BUNDLE_IN is the
# provenance JSONL the attest job staged. Each per-artifact bundle is a copy of
# this seed plus that subject's VSA, so seeding runs once and BUNDLE_IN stays
# intact for a re-run.
wrangle_seed_bundle() {
    local seed="$1"
    if [[ -n "${OCI_TARGET:-}" ]]; then
        local args downloaded
        mapfile -t args < <(wrangle_cosign_download_args "$OCI_TARGET")
        # cosign download emits ALL referrers (provenance AND any VSA bundle a
        # prior run pushed). Keep only the SLSA provenance DSSE envelopes so a
        # re-run seeds the same base; a jq decode failure on the registry's
        # bytes must fail the step, not silently seed an empty bundle.
        downloaded="$(mktemp "${RUNNER_TEMP:-/tmp}/seed.XXXXXX")"
        cosign "${args[@]}" > "$downloaded"
        if ! jq -ce "select((.dsseEnvelope.payload | @base64d | fromjson | .predicateType) == \"$WRANGLE_PROVENANCE_PREDICATE\")" \
            "$downloaded" > "$seed"; then
            rm -f "$downloaded"
            printf 'wrangle: no SLSA provenance referrer found on %s (or malformed DSSE)\n' "$OCI_TARGET" >&2
            return 1
        fi
        rm -f "$downloaded"
    else
        cp "$BUNDLE_IN" "$seed"
    fi
}

# Map a subject to its per-artifact bundle basename. The subject is either a
# dist path (dist/foo.tar.gz) or an OCI digest (sha256:<hex>); take the path
# basename and replace the digest's colon so the result is a plain filename.
# verify-vsa self-selects each artifact's VSA from <artifact-basename>.intoto.jsonl.
wrangle_bundle_name() {
    local subject="$1" base="${1##*/}"
    printf '%s.intoto.jsonl\n' "${base//:/-}"
}

# Push the bundle at $1 to the registry as its own referrer (container only),
# best-effort. `cosign attach attestation` accepts a single per-artifact bundle
# (one Sigstore-bundle line, payloadType under .dsseEnvelope) and round-trips it
# verbatim via cosign download, preserving verificationMaterial; it rejects a
# multi-line concatenation. The workflow-artifact upload is the guaranteed
# delivery, so a registry-push failure is logged and swallowed rather than
# failing the job — the consumer can always fetch the file bundle.
wrangle_push_bundle() {
    [[ -z "${OCI_TARGET:-}" ]] && return 0
    local args
    mapfile -t args < <(wrangle_cosign_attach_args "$1" "$OCI_TARGET")
    if ! cosign "${args[@]}"; then
        printf 'wrangle: registry referrer push failed for %s (best-effort); the bundle is still delivered as the workflow artifact\n' "$1" >&2
    fi
}

# Verify every subject, sign its VSA, and write one <artifact>.intoto.jsonl per
# subject into the BUNDLE_OUT directory (the shared provenance seed plus that
# subject's signed VSA) — all in one process so an unsigned VSA never crosses a
# step boundary. The unsigned VSA stays in $RUNNER_TEMP, never a persisted
# artifact.
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
    # The artifact-name arg is a fixed valid placeholder, not the action's real
    # artifact-name input: that input flows only into upload-artifact's name:,
    # never a shell command here, so this script doesn't validate it.
    # shellcheck disable=SC2153 # env-var inputs; the sourced validate script's lowercase locals trip the misspelling heuristic
    local subject
    for subject in "${WRANGLE_SUBJECTS[@]}"; do
        wrangle_validate_verify_inputs "vsa.intoto.jsonl" "$subject" "$POLICY" \
            "$COLLECTOR" "$FAIL" "${CONTEXT:-}" "${ATTESTATION:-}" "${OCI_TARGET:-}"
    done

    mkdir -p "$BUNDLE_OUT"
    local seed tmp_vsa
    seed="$(mktemp "${RUNNER_TEMP:-/tmp}/seed.XXXXXX")"
    wrangle_seed_bundle "$seed"

    tmp_vsa="$(mktemp "${RUNNER_TEMP:-/tmp}/vsa.XXXXXX")"
    local bundle
    for subject in "${WRANGLE_SUBJECTS[@]}"; do
        bundle="$BUNDLE_OUT/$(wrangle_bundle_name "$subject")"
        cp "$seed" "$bundle"
        wrangle_verify_emit_vsa "$subject" "$tmp_vsa"
        wrangle_sign_vsa "$tmp_vsa"
        # bnd emits a multi-line pretty statement; jq -c flattens it to the one
        # JSON-object-per-line a JSONL bundle requires.
        jq -c . "$tmp_vsa" >> "$bundle"
        # Push this per-artifact bundle to the registry best-effort (container).
        wrangle_push_bundle "$bundle"
    done
    rm -f "$tmp_vsa" "$seed"
}

# Attach every per-artifact bundle to the GitHub release for the current tag,
# IF one exists. wrangle does not create releases — the adopter's release
# tooling owns that; on a tag with no release the bundles remain available as
# the workflow artifact. Enumerate via a temp file (not a process substitution,
# whose exit status bash never observes) so a find that dies mid-traversal
# fails closed rather than attaching a partial set.
wrangle_attach_release() {
    local ref="$GITHUB_REF_NAME"
    if ! gh release view "$ref" >/dev/null 2>&1; then
        printf 'wrangle: no GitHub release for %s; the bundles are the workflow artifact only.\n' "$ref" >&2
        return 0
    fi
    local listing bundle
    listing="$(mktemp "${RUNNER_TEMP:-/tmp}/bundles.XXXXXX")"
    if ! find "$BUNDLE_OUT" -type f -name '*.intoto.jsonl' -print0 | sort -z > "$listing"; then
        rm -f "$listing"
        printf 'wrangle: failed to enumerate bundles under %s\n' "$BUNDLE_OUT" >&2
        return 1
    fi
    while IFS= read -r -d '' bundle; do
        gh release upload "$ref" "$bundle" --clobber
    done < "$listing"
    rm -f "$listing"
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
