#!/bin/bash
# Append the signed VSA to each per-artifact <artifact>.intoto.jsonl bundle the
# attest job assembled (provenance + that subject's signed SBOM + scan/v1), and
# deliver the result.
#
# Subcommands:
#   run    per subject: verify against the policy, sign the VSA, and append it to
#          the attest-assembled bundle — all in one process, so an unsigned VSA
#          never lives on disk across a step boundary. Each signed VSA is also
#          posted to the GitHub attestation store (by-digest discovery); with
#          OCI_TARGET set it is additionally pushed as its own OCI referrer. The
#          SBOM + scan/v1 metadata is signed AND assembled into the bundle in the
#          attest job (all build types); verify only appends the VSA.
#   attach upload the rationalized asset set (per-subject dist + bundle, and one
#          <type>-metadata-<sn>.zip) to the GitHub release for the current tag,
#          if one exists. Inputs: BUNDLE_OUT, BUILD_TYPE, DIST_DIR,
#          METADATA_ROOT (zipped into the metadata asset), METADATA_ZIP_NAME.
#
# Arg-builder functions are pure so unit tests can assert the CLI shape offline.
# Inputs arrive as env vars: SUBJECTS (newline-separated), POLICY, COLLECTOR,
# FAIL, CONTEXT, BUNDLE_IN (the attest-assembled bundle directory), BUNDLE_OUT,
# GITHUB_REPOSITORY (store push target), GITHUB_TOKEN (bnd reads it to auth the
# store push), and optional ATTESTATION and OCI_TARGET.

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

# Shared build-metadata primitives, also used by the attest job: wrangle_retry_once,
# wrangle_push_store, wrangle_push_oci_referrer, wrangle_read_subjects.
# shellcheck source=../../lib/sign_metadata.sh
source "$LIB_DIR/sign_metadata.sh"

# shellcheck source=../../lib/read_catalog.sh
source "$LIB_DIR/read_catalog.sh"
# shellcheck source=../../lib/verify_image_vsa.sh
source "$LIB_DIR/verify_image_vsa.sh"
# Toolbox dispatch (image resolution + VSA gate + hardened docker run + token
# mint), shared with the attest job's signer helpers.
# shellcheck source=../../lib/toolbox_run.sh
source "$LIB_DIR/toolbox_run.sh"

WRANGLE_CATALOG="${WRANGLE_CATALOG:-$REPO_ROOT/tools/catalog.json}"

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
# $2 = unsigned-VSA output; $3 = the attest-assembled per-artifact bundle
# (provenance + that subject's SBOM/scan), fed as a jsonl: collector so the
# verdict (and VSA) cover those tenets. COLLECTOR (when set, e.g. container's
# oci:) is an additional collector. Must be a collector, not --attestation (which
# parses only one statement; the bundle is multi-line).
wrangle_ampel_verify_args() {
    local subject="$1" results_path="$2" bundle="$3"
    # Capture (not process-substitute) so a subject-hashing failure aborts.
    local subject_arg
    subject_arg="$(wrangle_subject_arg "$subject")"
    local args=(verify "$subject_arg"
        --collector="jsonl:$bundle")
    [[ -n "${COLLECTOR:-}" ]] && args+=(--collector="$COLLECTOR")
    # shellcheck disable=SC2153 # env-var inputs; the sourced validate script's lowercase locals trip the misspelling heuristic
    args+=(--policy="$(wrangle_resolve_policy "$POLICY")"
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

# Run ampel verify in the VSA-gated toolbox image. The bundle, results path, and
# (relative) BUNDLE_OUT ride the workspace/temp mounts; only the policy dir needs
# an extra mount — a disk policy resolves under the action checkout, outside the
# workspace (a *://* locator is fetched, not read). An oci: collector reads
# attestations from ghcr, so it also gets the job's registry login and token.
wrangle_ampel() {
    local policy
    policy="$(wrangle_resolve_policy "$POLICY")"
    local -a extra=()
    case "$policy" in
        *://*) ;;
        *)     extra+=(--mount "$(dirname "$policy")") ;;
    esac
    [[ -n "${COLLECTOR:-}" ]] && extra+=(--docker-config --env GITHUB_TOKEN)
    wrangle_toolbox_exec "${extra[@]}" -- ampel "$@"
}

# ampel verify one subject -> unsigned VSA at $2, streaming the report to the
# step summary. $1 is the subject; $3 the attest-assembled bundle fed to the
# policy as the jsonl collector.
wrangle_verify_emit_vsa() {
    local subject="$1" results_path="$2" bundle="$3"
    local args report rc=0
    mapfile -t args < <(wrangle_ampel_verify_args "$subject" "$results_path" "$bundle")
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
    wrangle_retry_once "$report" wrangle_ampel "${args[@]}" || rc=$?
    wrangle_sanitize_output < "$report" >> "$GITHUB_STEP_SUMMARY"
    # The step summary is easy to miss, so echo a failed report to the job log.
    if [[ "$rc" -ne 0 ]]; then
        printf 'wrangle: ampel verification failed for %s (exit %s):\n' "$subject" "$rc" >&2
        cat "$report" >&2
    fi
    rm -f "$report"
    return "$rc"
}

# bnd-sign the unsigned VSA at $1 in place (in the toolbox container, minting a
# step-local SIGSTORE_ID_TOKEN threaded by name); the signed statement lands at $1.
wrangle_sign_vsa() {
    local vsa="$1"
    local args
    mapfile -t args < <(wrangle_bnd_sign_args "$vsa.unsigned")
    mv "$vsa" "$vsa.unsigned"
    local rc=0
    wrangle_retry_once "$vsa" wrangle_toolbox_exec \
        --sigstore -- bnd "${args[@]}" || rc=$?
    rm -f "$vsa.unsigned"
    # bnd can exit 0 yet emit nothing; an empty output would silently append no
    # VSA line to the bundle (jq -c on empty input yields nothing). Fail closed,
    # matching the attest side (lib/sign_metadata.sh).
    if [[ "$rc" -eq 0 && ! -s "$vsa" ]]; then
        printf 'wrangle: VSA signing produced no output for %s\n' "$vsa" >&2
        return 1
    fi
    return "$rc"
}

# Push the signed VSA at $1 as its own OCI referrer (container only). Fails
# closed: a missing by-digest VSA is a real delivery gap. No-op without OCI_TARGET.
wrangle_push_bundle() {
    wrangle_push_oci_referrer "$1"
}

# Verify every subject, sign its VSA, and append it to that subject's
# attest-assembled bundle — all in one process so an unsigned VSA never crosses a
# boundary.
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
    local tmp_vsa vsa_line
    tmp_vsa="$(mktemp "${RUNNER_TEMP:-/tmp}/vsa.XXXXXX")"
    vsa_line="$(mktemp "${RUNNER_TEMP:-/tmp}/vsaline.XXXXXX")"
    local name src bundle
    for subject in "${WRANGLE_SUBJECTS[@]}"; do
        name="$(wrangle_bundle_name "$subject")"
        # Fail closed: the attest job assembled this subject's provenance + signed
        # metadata into BUNDLE_IN; a missing bundle is a wiring/attest bug, never a
        # VSA-only bundle.
        src="$BUNDLE_IN/$name"
        if [[ ! -s "$src" ]]; then
            printf 'wrangle: attest-assembled bundle %s missing or empty\n' "$src" >&2
            rm -f "$tmp_vsa" "$vsa_line"
            return 1
        fi
        bundle="$BUNDLE_OUT/$name"
        # When BUNDLE_OUT == BUNDLE_IN (the metadata dir) the bundle is already in
        # place; otherwise stage attest's copy so the VSA appends to it.
        [[ "$src" -ef "$bundle" ]] || cp "$src" "$bundle"
        # Verify against the policy, feeding the bundle (provenance + SBOM/scan) as
        # the jsonl collector so the verdict/VSA cover those tenets.
        wrangle_verify_emit_vsa "$subject" "$tmp_vsa" "$bundle"
        wrangle_sign_vsa "$tmp_vsa"
        # Flatten bnd's pretty statement to one JSON line: appended to the bundle,
        # posted to the store, and pushed alone as the OCI referrer (cosign attach
        # rejects multi-line).
        jq -c . "$tmp_vsa" > "$vsa_line"
        cat "$vsa_line" >> "$bundle"
        wrangle_push_store "$vsa_line"
        wrangle_push_bundle "$vsa_line"
    done
    rm -f "$tmp_vsa" "$vsa_line"
}

# Attach the rationalized asset set to the current tag's GitHub release, creating
# a published release for the tag if none exists. Per subject: the <artifact> dist file
# and its <artifact>.intoto.jsonl bundle (flat); once per build: a
# <type>-metadata-<sn>.zip of the metadata dir (sbom + scan/ + bundles). The
# dist is attached alongside its bundle so no bundle is orphaned without its
# artifact. For go, wrangle owns the publish: it also attaches checksums.txt
# (goreleaser built but published nothing). Enumerate via a temp file, not a
# process substitution, so a find that dies mid-traversal fails closed.
wrangle_attach_release() {
    local ref="$GITHUB_REF_NAME" create_err
    # Create the tag's release if absent. A peer build-type job sharing it can win
    # the create race, so re-check existence and fail closed only if still absent.
    if ! gh release view "$ref" >/dev/null 2>&1; then
        if ! create_err="$(gh release create "$ref" --generate-notes --title "$ref" 2>&1)" \
            && ! gh release view "$ref" >/dev/null 2>&1; then
            printf 'wrangle: failed to create GitHub release for %s: %s\n' "$ref" "$create_err" >&2
            return 1
        fi
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
