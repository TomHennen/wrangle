#!/bin/bash
# Verify each subject, sign its VSA, and emit one <artifact>.intoto.jsonl bundle
# per subject (provenance lines + that subject's signed VSA).
#
# Subcommands:
#   run    emit -> sign -> append per subject in one process, so an unsigned VSA
#          never lives on disk across a step boundary. Each signed VSA is also
#          posted to the GitHub attestation store (by-digest discovery); with
#          OCI_TARGET set it is additionally pushed as its own OCI referrer.
#   attach upload every bundle to the GitHub release for the current tag, if any.
#
# Arg-builder functions are pure so unit tests can assert the CLI shape offline.
# Inputs arrive as env vars: SUBJECTS (newline-separated), POLICY, COLLECTOR,
# FAIL, CONTEXT, BUNDLE_IN, BUNDLE_OUT, GITHUB_REPOSITORY (store push target),
# GITHUB_TOKEN (bnd reads it to auth the store push), and optional ATTESTATION,
# OCI_TARGET, METADATA_ROOT (the metadata dir wrangle-attest reads for the
# top-level SBOM and scan/<tool>/ manifests, signed by the engine and appended
# per subject), COMMIT (scanned git commit woven into the scan/v1 envelope).

set -euo pipefail
set -f  # disable globbing — processes external input

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$VERIFY_DIR/../../lib" && pwd)"
REPO_ROOT="$(cd "$VERIFY_DIR/../.." && pwd)"

# Resolve a relative policy path against the action's checkout (where the
# PolicySets ship), not the caller's CWD. Absolute paths and ampel locators
# (anything with ://) pass through unchanged.
wrangle_resolve_policy() {
    case "$1" in
        /*|*://*) printf '%s\n' "$1" ;;
        *)        printf '%s\n' "$REPO_ROOT/$1" ;;
    esac
}

# Run a command, retrying once on failure to absorb transient Sigstore I/O.
# Re-evaluation is deterministic, so a retry can only flip a transient failure.
# $1 is the stdout capture, truncated per attempt. WRANGLE_RETRY_DELAY spaces
# the attempts (tests set it to 0).
wrangle_retry_once() {
    local out="$1"; shift
    "$@" > "$out" && return 0
    local rc=$?
    printf 'wrangle: %s failed (exit %s); retrying once for transient Sigstore I/O\n' "$1" "$rc" >&2
    sleep "${WRANGLE_RETRY_DELAY:-5}"
    "$@" > "$out"
}

# Emit the ampel subject flag for one subject, one arg per line. A digest-form
# subject (algo:hex, e.g. a container) passes through; a file subject is hashed
# to sha256 ourselves and passed as --subject-hash so the VSA subject carries a
# single sha256 digest — ampel's file hasher emits sha256+sha512, but the GitHub
# attestation store rejects a multi-digest subject.
wrangle_subject_arg() {
    local subject="$1" digest
    if [[ "$subject" =~ ^[a-z0-9]+:[a-f0-9]+$ ]]; then
        printf -- '--subject=%s\n' "$subject"
        return 0
    fi
    # A missing/unreadable subject file must fail closed, not yield an empty hash.
    digest="$(sha256sum "$subject")" || return 1
    printf -- '--subject-hash=sha256:%s\n' "${digest%% *}"
}

# Build the ampel verify arg vector for one subject, one arg per line for
# mapfile. $1 is the subject; $2 the unsigned-VSA output path.
wrangle_ampel_verify_args() {
    local subject="$1" results_path="$2"
    # Capture (not process-substitute) so a subject-hashing failure aborts.
    local subject_arg
    subject_arg="$(wrangle_subject_arg "$subject")"
    local args=(verify "$subject_arg"
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

# Build the cosign arg vector that downloads the image's attestation referrers
# as newline-delimited DSSE envelopes. $1 is the image digest ref.
wrangle_cosign_download_args() {
    printf '%s\n' download attestation "$1"
}

# Build the cosign arg vector that pushes a single VSA statement as an OCI
# referrer. `attach attestation` uploads verbatim (no re-sign), preserving the
# bnd signer; it accepts only one bundle line. $1 is the VSA-only file, $2 the
# image digest ref.
wrangle_cosign_attach_args() {
    printf '%s\n' attach attestation \
        --attestation "$1" \
        "$2"
}

# Build the bnd arg vector that posts a signed VSA to the GitHub attestation
# store. $1 is <owner>/<repo>; $2 the bnd-signed VSA file. The store is keyed
# by subject digest, giving consumers by-digest discovery via ampel's github:
# collector.
wrangle_bnd_push_args() {
    printf '%s\n' push github "$1" "$2"
}

# Split SUBJECTS into an array, dropping blank lines. Fail closed on an empty
# set: zero subjects would emit a provenance-only bundle with no VSA.
wrangle_read_subjects() {
    mapfile -t WRANGLE_SUBJECTS <<< "$SUBJECTS"
    local s kept=()
    for s in "${WRANGLE_SUBJECTS[@]}"; do
        [[ "$s" =~ ^[[:space:]]*$ ]] || kept+=("$s")
    done
    WRANGLE_SUBJECTS=("${kept[@]}")
    if [[ "${#WRANGLE_SUBJECTS[@]}" -eq 0 ]]; then
        printf 'wrangle: no subjects to verify — refusing to emit a VSA-less bundle\n' >&2
        return 1
    fi
}

# ampel verify one subject -> unsigned VSA at $2, streaming the report to the
# step summary. $1 is the subject.
wrangle_verify_emit_vsa() {
    local subject="$1" results_path="$2"
    local args report rc=0
    mapfile -t args < <(wrangle_ampel_verify_args "$subject" "$results_path")
    # Fail closed: an aborted arg builder (e.g. a subject file we couldn't hash)
    # yields a short/empty vector, never a silently mis-verified subject.
    if [[ "${args[0]:-}" != "verify" || "${args[1]:-}" != --subject* ]]; then
        printf 'wrangle: could not build ampel args for %s\n' "$subject" >&2
        return 2
    fi

    # Capture the report to a file before sanitizing: ampel's --exit-code carries
    # the policy verdict, and piping straight into the truncating sanitizer could
    # SIGPIPE ampel and flip a PASS into a blocked release.
    report="$(mktemp)"
    wrangle_retry_once "$report" ampel "${args[@]}" || rc=$?
    wrangle_sanitize_output < "$report" >> "$GITHUB_STEP_SUMMARY"
    # The step summary is easy to miss, so echo a failed report to the job log.
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

# Predicate the seed filters to, so a re-run drops prior VSA referrers and
# rebuilds the same bundle (idempotent round-trip).
WRANGLE_PROVENANCE_PREDICATE="https://slsa.dev/provenance/v1"

# Write the shared provenance seed to $1: from the OCI referrer (container) or
# BUNDLE_IN (otherwise). Each bundle copies this seed, so it runs once.
wrangle_seed_bundle() {
    local seed="$1"
    if [[ -n "${OCI_TARGET:-}" ]]; then
        local args downloaded
        mapfile -t args < <(wrangle_cosign_download_args "$OCI_TARGET")
        # Keep only the SLSA provenance envelopes (download emits all referrers,
        # including prior VSAs); a jq decode failure must fail, not seed empty.
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

# Map a subject (dist path or sha256: digest) to its bundle filename: basename
# with the digest's colon replaced.
wrangle_bundle_name() {
    local subject="$1" base="${1##*/}"
    printf '%s.intoto.jsonl\n' "${base//:/-}"
}

# Push the signed VSA at $1 as its own OCI referrer (container only). Fails
# closed: a missing by-digest VSA is a real delivery gap. No-op without OCI_TARGET.
wrangle_push_bundle() {
    [[ -z "${OCI_TARGET:-}" ]] && return 0
    local args
    mapfile -t args < <(wrangle_cosign_attach_args "$1" "$OCI_TARGET")
    wrangle_retry_once /dev/null cosign "${args[@]}"
}

# Build the wrangle-attest arg vector that turns the build metadata into signed
# in-toto statements (one signed Sigstore-bundle JSONL line per statement), one
# arg per line for mapfile. $1 is the pre-formed subject arg (--subject=<digest>
# or --artifact=<file>); $2 the JSONL output path. METADATA_ROOT holds the
# build's wrangle_attestation_metadata.json files (the SBOM's, the scan tools'
# scan/v1); COMMIT is the scanned git commit woven into the scan/v1 envelope
# only, ignored by the SBOM passthrough.
wrangle_attest_args() {
    printf '%s\n' \
        --metadata-root="$METADATA_ROOT" \
        "$1" \
        --commit="${COMMIT:-}" \
        --sign \
        --out="$2"
}

# For one subject, build and sign the SBOM (and any other build-metadata)
# statement(s) via the engine, then append each signed line to the bundle and
# post each to the store. No-op when METADATA_ROOT is unset/empty (a build that
# produced no metadata). $1 is the subject, $2 the bundle file. A digest subject
# (container) passes through as --subject; a file subject is handed to the
# engine via --artifact, which self-digests it to the same sha256 the VSA binds
# to. The engine signs in the same trusted process as the VSA and fails closed
# on a malformed manifest, an unreadable artifact, or a signing failure (no
# partial bundle), so an absent statement is a real gap, not a silent skip.
wrangle_emit_metadata_statements() {
    [[ -z "${METADATA_ROOT:-}" || ! -d "${METADATA_ROOT:-}" ]] && return 0
    local subject="$1" bundle="$2" subject_arg
    if [[ "$subject" =~ ^[a-z0-9]+:[a-f0-9]+$ ]]; then
        subject_arg="--subject=$subject"
    else
        subject_arg="--artifact=$subject"
    fi
    local stmts args
    stmts="$(mktemp "${RUNNER_TEMP:-/tmp}/attest.XXXXXX")"
    mapfile -t args < <(wrangle_attest_args "$subject_arg" "$stmts")
    wrangle_retry_once /dev/null wrangle-attest "${args[@]}" || { rm -f "$stmts"; return 1; }
    # Each line is one signed Sigstore bundle (compact JSONL): appended to the
    # bundle, posted to the store, and pushed alone as the OCI referrer (cosign
    # attach rejects multi-line).
    local line_file
    line_file="$(mktemp "${RUNNER_TEMP:-/tmp}/attestline.XXXXXX")"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        printf '%s\n' "$line" > "$line_file"
        cat "$line_file" >> "$bundle"
        wrangle_push_store "$line_file"
        wrangle_push_bundle "$line_file"
    done < "$stmts"
    rm -f "$stmts" "$line_file"
}

# Post the signed VSA at $1 to the GitHub attestation store (all build types).
# Provenance is already in the store from attest-build-provenance, so only the
# VSA is pushed. Fails closed: a missing by-digest VSA is a real delivery gap.
wrangle_push_store() {
    local args
    mapfile -t args < <(wrangle_bnd_push_args "$GITHUB_REPOSITORY" "$1")
    wrangle_retry_once /dev/null bnd "${args[@]}"
}

# Verify every subject, sign its VSA, and write one bundle per subject into
# BUNDLE_OUT — all in one process so an unsigned VSA never crosses a boundary.
wrangle_run() {
    # shellcheck source=validate_verify_inputs.sh
    source "$VERIFY_DIR/validate_verify_inputs.sh"

    # shellcheck source=../../lib/env.sh
    source "$LIB_DIR/env.sh"
    # shellcheck source=../../lib/sanitize.sh
    source "$LIB_DIR/sanitize.sh"

    local -a WRANGLE_SUBJECTS
    wrangle_read_subjects

    # Validate each subject; shared inputs revalidate identically. The artifact-
    # name arg is a fixed placeholder — that input never reaches a shell command.
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
    local vsa_line
    vsa_line="$(mktemp "${RUNNER_TEMP:-/tmp}/vsaline.XXXXXX")"
    local bundle
    for subject in "${WRANGLE_SUBJECTS[@]}"; do
        bundle="$BUNDLE_OUT/$(wrangle_bundle_name "$subject")"
        cp "$seed" "$bundle"
        wrangle_verify_emit_vsa "$subject" "$tmp_vsa"
        wrangle_sign_vsa "$tmp_vsa"
        # Flatten bnd's pretty statement to one JSON line: appended to the bundle,
        # posted to the store, and pushed alone as the OCI referrer (cosign attach
        # rejects multi-line).
        jq -c . "$tmp_vsa" > "$vsa_line"
        cat "$vsa_line" >> "$bundle"
        wrangle_push_store "$vsa_line"
        wrangle_push_bundle "$vsa_line"
        # Append the build-metadata statements (SBOM, …) bound to this same
        # single-sha256 subject, signed and delivered alongside the VSA.
        wrangle_emit_metadata_statements "$subject" "$bundle"
    done
    rm -f "$tmp_vsa" "$vsa_line" "$seed"
}

# Attach every bundle to the current tag's GitHub release, if one exists
# (wrangle never creates releases). Enumerate via a temp file, not a process
# substitution, so a find that dies mid-traversal fails closed.
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
