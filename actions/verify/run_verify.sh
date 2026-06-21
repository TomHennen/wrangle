#!/bin/bash
# Verify each subject, sign its VSA, and emit one <artifact>.intoto.jsonl bundle
# per subject (provenance lines + that subject's signed VSA).
#
# Subcommands:
#   run    emit -> sign -> append per subject in one process, so an unsigned VSA
#          never lives on disk across a step boundary. Each signed VSA is also
#          posted to the GitHub attestation store (by-digest discovery); with
#          OCI_TARGET set it is additionally pushed as its own OCI referrer. The
#          SBOM + scan/v1 metadata is signed in the attest job and consumed here
#          (SIGNED_METADATA) — verify never re-signs or re-pushes it.
#   attach upload the rationalized asset set (per-subject dist + bundle, and one
#          <type>-metadata-<sn>.zip) to the GitHub release for the current tag,
#          if one exists. Inputs: BUNDLE_OUT, BUILD_TYPE, DIST_DIR,
#          METADATA_ROOT (zipped into the metadata asset), METADATA_ZIP_NAME.
#
# Arg-builder functions are pure so unit tests can assert the CLI shape offline.
# Inputs arrive as env vars: SUBJECTS (newline-separated), POLICY, COLLECTOR,
# FAIL, CONTEXT, BUNDLE_IN, BUNDLE_OUT, GITHUB_REPOSITORY (store push target),
# GITHUB_TOKEN (bnd reads it to auth the store push), and optional ATTESTATION,
# OCI_TARGET, SIGNED_METADATA (the attest job's signed SBOM + scan/v1 statements
# JSONL — already signed and store-pushed there; verify reads it, never re-signs
# or re-pushes).

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

# Shared primitives: wrangle_retry_once, wrangle_bnd_push_args (VSA store push),
# wrangle_push_store, wrangle_read_subjects. The metadata is signed in attest;
# verify uses only the VSA-side primitives here.
# shellcheck source=../../lib/sign_metadata.sh
source "$LIB_DIR/sign_metadata.sh"

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

# Build the ampel verify arg vector (one arg per line for mapfile). $1 = subject;
# $2 = unsigned-VSA output; $3 (optional) = signed-metadata JSONL, added as a second
# jsonl: collector so the verdict (and VSA) cover the SBOM/scan tenets. Must be a
# collector, not --attestation (which parses only one statement; metadata is multi-line).
wrangle_ampel_verify_args() {
    local subject="$1" results_path="$2" metadata="${3:-}"
    # Capture (not process-substitute) so a subject-hashing failure aborts.
    local subject_arg
    subject_arg="$(wrangle_subject_arg "$subject")"
    local args=(verify "$subject_arg"
        --collector="$COLLECTOR")
    [[ -n "$metadata" ]] && args+=(--collector="jsonl:$metadata")
    # ampel drops the signer-identity match on tenets beyond --workers; keep it
    # above the largest tier's tenet count (strict: 8) until carabiner-dev/ampel#298 lands.
    args+=(--policy="$(wrangle_resolve_policy "$POLICY")"
        --workers=32
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

# ampel verify one subject -> unsigned VSA at $2, streaming the report to the
# step summary. $1 is the subject; $3 (optional) the engine-signed metadata
# JSONL fed to the policy alongside the collector.
wrangle_verify_emit_vsa() {
    local subject="$1" results_path="$2" metadata="${3:-}"
    local args report rc=0
    mapfile -t args < <(wrangle_ampel_verify_args "$subject" "$results_path" "$metadata")
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

# Append each already-signed metadata line at $1 to the bundle $2. The attest
# job signed these and posted them to the store, so verify only assembles the
# consumer bundle — it does NOT re-push to the store or OCI. No-op on an
# empty/absent file (no metadata for this build).
wrangle_append_metadata_statements() {
    local stmts="$1" bundle="$2"
    [[ -s "$stmts" ]] || return 0
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        printf '%s\n' "$line" >> "$bundle"
    done < "$stmts"
}

# Filter the attest-signed metadata JSONL $1 to the lines whose in-toto subject
# digest matches subject $2, writing them to $3 (emptied first). Each line is a
# bnd DSSE bundle; the subject sits inside the base64 payload. A file subject is
# sha256-hashed (the digest attest bound); a digest-form subject matches verbatim.
# Fails closed: an unhashable subject or a malformed line aborts, never silently
# emitting an empty per-subject set when the artifact carries metadata.
wrangle_subject_signed_metadata() {
    local signed="$1" subject="$2" out="$3" digest
    : > "$out"
    [[ -s "$signed" ]] || return 0
    if [[ "$subject" =~ ^[a-z0-9]+:[a-f0-9]+$ ]]; then
        digest="${subject#*:}"
    else
        local sum
        sum="$(sha256sum "$subject")" || return 1
        digest="${sum%% *}"
    fi
    jq -c --arg d "$digest" \
        'select((.dsseEnvelope.payload | @base64d | fromjson | .subject[0].digest.sha256) == $d)' \
        "$signed" > "$out"
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

    # The attest job signed the SBOM/scan metadata into this JSONL; fail closed
    # if a build that has metadata produced no signed set (a wiring/attest bug),
    # so verify never emits a VSA-only bundle for a build that has metadata.
    if [[ -n "${SIGNED_METADATA:-}" && ! -s "$SIGNED_METADATA" ]]; then
        printf 'wrangle: signed-metadata artifact %s missing or empty\n' "$SIGNED_METADATA" >&2
        return 1
    fi

    mkdir -p "$BUNDLE_OUT"
    local seed tmp_vsa
    seed="$(mktemp "${RUNNER_TEMP:-/tmp}/seed.XXXXXX")"
    wrangle_seed_bundle "$seed"

    tmp_vsa="$(mktemp "${RUNNER_TEMP:-/tmp}/vsa.XXXXXX")"
    local vsa_line meta_stmts
    vsa_line="$(mktemp "${RUNNER_TEMP:-/tmp}/vsaline.XXXXXX")"
    meta_stmts="$(mktemp "${RUNNER_TEMP:-/tmp}/meta.XXXXXX")"
    local bundle
    for subject in "${WRANGLE_SUBJECTS[@]}"; do
        bundle="$BUNDLE_OUT/$(wrangle_bundle_name "$subject")"
        cp "$seed" "$bundle"
        # Select this subject's attest-signed SBOM/scan statements so ampel
        # evaluates the policy against them (a second collector), then bind the
        # verdict into the VSA. Pass the file to ampel only when it holds
        # statements — the extra collector is omitted for a build with no metadata.
        : > "$meta_stmts"
        [[ -n "${SIGNED_METADATA:-}" ]] \
            && wrangle_subject_signed_metadata "$SIGNED_METADATA" "$subject" "$meta_stmts"
        local meta_arg=""
        [[ -s "$meta_stmts" ]] && meta_arg="$meta_stmts"
        wrangle_verify_emit_vsa "$subject" "$tmp_vsa" "$meta_arg"
        wrangle_sign_vsa "$tmp_vsa"
        # Flatten bnd's pretty statement to one JSON line: appended to the bundle,
        # posted to the store, and pushed alone as the OCI referrer (cosign attach
        # rejects multi-line).
        jq -c . "$tmp_vsa" > "$vsa_line"
        cat "$vsa_line" >> "$bundle"
        wrangle_push_store "$vsa_line"
        wrangle_push_bundle "$vsa_line"
        # Deliver the same attest-signed SBOM/scan statements alongside the VSA
        # (already signed + pushed by attest — appended only, never re-pushed).
        wrangle_append_metadata_statements "$meta_stmts" "$bundle"
    done
    rm -f "$tmp_vsa" "$vsa_line" "$meta_stmts" "$seed"
}

# Attach the rationalized asset set to the current tag's GitHub release, if one
# exists (wrangle never creates releases). Per subject: the <artifact> dist file
# and its <artifact>.intoto.jsonl bundle (flat); once per build: a
# <type>-metadata-<sn>.zip of the metadata dir (sbom + scan/ + bundles). The
# dist is attached alongside its bundle so no bundle is orphaned without its
# artifact. For go, wrangle owns the publish: it also attaches checksums.txt
# (goreleaser built but published nothing). Enumerate via a temp file, not a
# process substitution, so a find that dies mid-traversal fails closed.
wrangle_attach_release() {
    local ref="$GITHUB_REF_NAME"
    if ! gh release view "$ref" >/dev/null 2>&1; then
        printf 'wrangle: no GitHub release for %s; the bundles are the workflow artifact only.\n' "$ref" >&2
        return 0
    fi
    local listing bundle base dist rc=0
    listing="$(mktemp "${RUNNER_TEMP:-/tmp}/bundles.XXXXXX")"
    if ! find "$BUNDLE_OUT" -type f -name '*.intoto.jsonl' -print0 | sort -z > "$listing"; then
        rm -f "$listing"
        printf 'wrangle: failed to enumerate bundles under %s\n' "$BUNDLE_OUT" >&2
        return 1
    fi
    # Fail closed before any upload if two bundles share a basename: assets attach
    # by basename, so a collision would clobber or cross-wire a release asset.
    local dup
    dup="$(tr '\0' '\n' < "$listing" | sed 's#.*/##' | sort | uniq -d | head -n1)"
    if [[ -n "$dup" ]]; then
        rm -f "$listing"
        printf 'wrangle: duplicate release-asset basename %s — refusing to clobber\n' "$dup" >&2
        return 1
    fi
    while IFS= read -r -d '' bundle; do
        gh release upload "$ref" "$bundle" --clobber
        # Attach the dist sibling alongside its bundle so no bundle is orphaned.
        base="${bundle##*/}"
        dist="${DIST_DIR:-dist}/${base%.intoto.jsonl}"
        if [[ -f "$dist" ]]; then
            gh release upload "$ref" "$dist" --clobber
        else
            printf 'wrangle: dist file %s for bundle %s not found\n' "$dist" "$bundle" >&2
            rc=1
            break
        fi
    done < "$listing"
    rm -f "$listing"
    [[ "$rc" -ne 0 ]] && return "$rc"
    # go: the attested-artifact set includes checksums.txt — it's not a VSA
    # subject (it's the manifest the subjects derive from), so it has no bundle
    # of its own. goreleaser built it but published nothing; wrangle owns the
    # publish, so attach it too. Fail closed if it's missing.
    if [[ "${BUILD_TYPE:-}" == "go" ]]; then
        local checksums="${DIST_DIR:-dist}/checksums.txt"
        if [[ -f "$checksums" ]]; then
            gh release upload "$ref" "$checksums" --clobber
        else
            printf 'wrangle: go checksums.txt (%s) not found\n' "$checksums" >&2
            return 1
        fi
    fi
    wrangle_attach_metadata_zip "$ref"
}

# Zip the metadata dir (sbom + scan/ + bundles) and attach it once per build as
# <type>-metadata-<sn>.zip. The SBOM rides inside this zip, not as a flat asset.
wrangle_attach_metadata_zip() {
    local ref="$1" zip
    zip="${RUNNER_TEMP:-/tmp}/$METADATA_ZIP_NAME"
    rm -f "$zip"
    ( cd "$METADATA_ROOT" && zip -r -q "$zip" . )
    gh release upload "$ref" "$zip" --clobber
    rm -f "$zip"
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
