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
#          <type>-metadata-<sn>.zip) to the GitHub release for the current tag.
#          Inputs: BUNDLE_OUT, BUILD_TYPE, DIST_DIR, METADATA_ROOT (zipped into
#          the metadata asset), METADATA_ZIP_NAME.
#   attach-unattested  the disabled-attestation publish: no bundles/VSAs, so
#          upload the release artifacts (a checksums manifest scopes them when
#          present, else the flat dist) and the metadata zip, and mark the
#          release body unattested. Inputs: DIST_DIR, METADATA_ROOT, METADATA_ZIP_NAME.
#
# Both attach subcommands drive a draft -> attach-all -> publish flow: the
# release is created as a draft, every asset (and, for unattested, the body
# marker) is attached, then the draft is flipped to published as the final step.
# GitHub immutable releases freeze a release at publish, so no asset or body edit
# may happen after the flip.
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

# Shared build-metadata primitives, also used by the attest job:
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

# Shared dist-artifact resolution (checksums manifest / glob) into WRANGLE_RESOLVED,
# the same resolvers the attest and verify jobs use to derive subjects.
# shellcheck source=../../lib/resolve_subjects.sh
source "$LIB_DIR/resolve_subjects.sh"

WRANGLE_CATALOG="${WRANGLE_CATALOG:-$REPO_ROOT/tools/catalog.json}"

# Build the wrangle-attest verify arg vector (one arg per line for mapfile).
# $1 = subject; $2 = signed-VSA output; $3 = the attest-assembled per-artifact
# bundle (provenance + that subject's SBOM/scan), which the engine feeds to the
# policy as ampel's jsonl: collector — so the verdict and VSA cover those
# tenets — and appends the signed VSA to. COLLECTOR (when set, e.g. container's
# oci:) is an additional collector. A digest-form subject passes through (the
# engine accepts sha256 only); a file subject is self-digested by the engine.
wrangle_engine_verify_args() {
    local subject="$1" out="$2" bundle="$3"
    local args=(verify)
    if [[ "$subject" =~ ^[a-z0-9]+:[a-f0-9]+$ ]]; then
        args+=(--subject="$subject")
    else
        args+=(--artifact="$subject")
    fi
    # shellcheck disable=SC2153 # env-var inputs; the sourced validate script's lowercase locals trip the misspelling heuristic
    args+=(--policy="$(wrangle_resolve_policy "$POLICY")"
        --bundle="$bundle"
        --fail="$FAIL"
        --out="$out")
    [[ -n "${COLLECTOR:-}" ]] && args+=(--collector="$COLLECTOR")
    [[ -n "${CONTEXT:-}" ]] && args+=(--context="$CONTEXT")
    [[ -n "${ATTESTATION:-}" ]] && args+=(--attestation="$ATTESTATION")
    printf '%s\n' "${args[@]}"
}

# Verify one subject in the VSA-gated toolbox image: wrangle-attest verify
# execs the in-image ampel against the policy, fail-closes unless ampel's exit
# code and the emitted VSA agree on the verdict, signs the VSA (step-local
# SIGSTORE_ID_TOKEN threaded by name), writes the signed line to $2, and
# appends it to the bundle at $3 — one container run, so an unsigned VSA never
# leaves the engine process. Only the policy dir needs an extra mount — a disk
# policy resolves under the action checkout, outside the workspace (a *://*
# locator is fetched, not read). An oci: collector reads attestations from
# ghcr, so the run also gets the job's registry login and token; the engine
# strips the signing token from ampel's environment. The engine retries the
# ampel exec internally; this run is not retried in-shell because a re-run
# after a completed bundle append would append the VSA twice.
wrangle_engine_verify() {
    local subject="$1" out="$2" bundle="$3"
    local args policy
    mapfile -t args < <(wrangle_engine_verify_args "$subject" "$out" "$bundle")
    policy="$(wrangle_resolve_policy "$POLICY")"
    local -a extra=()
    case "$policy" in
        *://*) ;;
        *)     extra+=(--mount "$(dirname "$policy")") ;;
    esac
    [[ -n "${COLLECTOR:-}" ]] && extra+=(--docker-config --env GITHUB_TOKEN)
    # Capture the report (the engine's stdout) to a file before sanitizing:
    # piping straight into the truncating sanitizer could SIGPIPE the engine
    # and flip a PASS into a blocked release.
    local report rc=0
    report="$(mktemp)"
    wrangle_toolbox_exec --sigstore "${extra[@]}" -- \
        wrangle-attest "${args[@]}" > "$report" || rc=$?
    wrangle_sanitize_output < "$report" >> "$GITHUB_STEP_SUMMARY"
    # The step summary is easy to miss, so echo a failed report to the job log.
    if [[ "$rc" -ne 0 ]]; then
        printf 'wrangle: verification failed for %s (exit %s):\n' "$subject" "$rc" >&2
        cat "$report" >&2
    fi
    rm -f "$report"
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
        # Verify against the policy, sign the VSA, and append it to the bundle;
        # the signed line also lands at tmp_vsa for the pushes below.
        wrangle_engine_verify "$subject" "$tmp_vsa" "$bundle"
        # jq -c exits 0 on empty input, so an engine that exited 0 without
        # landing the signed line host-side would push an empty statement.
        if [[ ! -s "$tmp_vsa" ]]; then
            printf 'wrangle: engine produced no signed VSA for %s\n' "$subject" >&2
            rm -f "$tmp_vsa" "$vsa_line"
            return 1
        fi
        # One statement per line for the store push and the OCI referrer (cosign
        # attach rejects multi-line).
        jq -c . "$tmp_vsa" > "$vsa_line"
        wrangle_push_store "$vsa_line"
        wrangle_push_bundle "$vsa_line"
    done
    rm -f "$tmp_vsa" "$vsa_line"
}

# Ensure a DRAFT release exists for $1, creating one if absent. A draft so every
# asset attaches before publish — GitHub immutable releases forbid post-publish
# asset changes (#407). Race-safe: a peer build-type job sharing the tag can win
# the create, so re-check existence and fail closed only if still absent.
wrangle_ensure_release() {
    local ref="$1" create_err
    gh release view "$ref" >/dev/null 2>&1 && return 0
    if ! create_err="$(gh release create "$ref" --draft --generate-notes --title "$ref" 2>&1)" \
        && ! gh release view "$ref" >/dev/null 2>&1; then
        printf 'wrangle: failed to create GitHub release for %s: %s\n' "$ref" "$create_err" >&2
        return 1
    fi
}

# Publish the tag's release: flip the ensure_release draft to published. The LAST
# asset/body mutation in an attach flow, so an immutable release freezes only
# once every asset is attached (#407). Tolerant of an already-published release
# (a peer build-type publish won the flip): re-check visibility and succeed.
wrangle_publish_release() {
    local ref="$1"
    gh release edit "$ref" --draft=false >/dev/null 2>&1 && return 0
    [[ "$(gh release view "$ref" --json isDraft -q .isDraft 2>/dev/null)" == "false" ]] && return 0
    printf 'wrangle: failed to publish release for %s\n' "$ref" >&2
    return 1
}

# Attach the rationalized asset set to the current tag's GitHub release, creating
# a draft for the tag if none exists and publishing it once every asset is
# attached. Per subject: the <artifact> dist file and its <artifact>.intoto.jsonl
# bundle (flat); once per build: a <type>-metadata-<sn>.zip of the metadata dir
# (sbom + scan/ + bundles). The dist is attached alongside its bundle so no
# bundle is orphaned without its artifact. For go, wrangle owns the publish: it
# also attaches checksums.txt (goreleaser built but published nothing). Enumerate
# via a temp file, not a process substitution, so a find that dies mid-traversal
# fails closed.
wrangle_attach_release() {
    local ref="$GITHUB_REF_NAME"
    wrangle_ensure_release "$ref" || return 1
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
    wrangle_attach_metadata_zip "$ref" || return 1
    wrangle_publish_release "$ref"
}

# Zip the metadata dir (sbom + scan/ + bundles) and attach it once per build as
# <type>-metadata-<sn>.zip. The SBOM rides inside this zip, not as a flat asset.
wrangle_attach_metadata_zip() {
    local ref="$1" zip rc=0
    zip="${RUNNER_TEMP:-/tmp}/$METADATA_ZIP_NAME"
    rm -f "$zip"
    # Capture each step's rc explicitly: this runs on the left of `||`, so set -e
    # is disabled throughout the body — a swallowed zip-build or upload failure
    # would let the caller flip the draft to published with an incomplete release.
    ( cd "$METADATA_ROOT" && zip -r -q "$zip" . ) || rc=1
    [[ "$rc" -eq 0 ]] && { gh release upload "$ref" "$zip" --clobber || rc=1; }
    rm -f "$zip"
    return "$rc"
}

# The marker appended to an unattested release body, and a substring unique to
# it used as the idempotency key (a generic alert line would false-match adopter
# notes and suppress the marker).
WRANGLE_UNATTESTED_MARKER='> [!WARNING]
> Unattested build (attest-and-verify: disabled) — no SLSA provenance or VSA. See https://github.com/TomHennen/wrangle/issues/600.'
WRANGLE_UNATTESTED_MARKER_KEY='Unattested build (attest-and-verify: disabled)'

# Append the unattested marker to the release body, preserving adopter-authored
# or generated notes. Idempotent: a re-run that finds the marker already present
# leaves the body untouched.
wrangle_mark_release_unattested() {
    local ref="$1" body
    body="$(gh release view "$ref" --json body -q .body)" || return 1
    case "$body" in
        *"$WRANGLE_UNATTESTED_MARKER_KEY"*) return 0 ;;
    esac
    [[ -n "$body" ]] && body+=$'\n\n'
    body+="$WRANGLE_UNATTESTED_MARKER"
    gh release edit "$ref" --notes "$body"
}

# Unattested publish (attest-and-verify: disabled): there are no bundles or VSAs, so
# attach every dist file (go: the archives + checksums.txt) and the metadata zip
# (sbom + scan/, no bundles). Same draft -> attach -> publish flow as the attested
# attach; only the per-subject bundle pairing is dropped. Mark the draft body
# unattested (before the publish flip, so the edit lands while still mutable) so a
# reader knows it carries no provenance.
wrangle_attach_unattested() {
    local ref="$GITHUB_REF_NAME"
    wrangle_ensure_release "$ref" || return 1
    wrangle_mark_release_unattested "$ref" || return 1
    local dist_dir="${DIST_DIR:-dist}" checksums="${DIST_DIR:-dist}/checksums.txt" dist
    # Reuse the attest/verify subject resolvers (lib/resolve_subjects.sh): a
    # checksums manifest names exactly the released artifacts — excluding any
    # build-tool bookkeeping dropped into dist/ (e.g. goreleaser's config.yaml) —
    # and add the manifest itself; without one (npm/python) every regular dist
    # file is an artifact.
    local -a WRANGLE_RESOLVED=()
    if [[ -f "$checksums" ]]; then
        wrangle_resolve_checksums "$checksums" || return 1
        WRANGLE_RESOLVED+=("$checksums")
    else
        wrangle_resolve_glob "$dist_dir/"'*' || return 1
    fi
    # Fail closed: nothing to publish means the build produced no artifacts.
    if [[ "${#WRANGLE_RESOLVED[@]}" -eq 0 ]]; then
        printf 'wrangle: no dist files to publish under %s\n' "$dist_dir" >&2
        return 1
    fi
    for dist in "${WRANGLE_RESOLVED[@]}"; do
        if [[ ! -f "$dist" ]]; then
            printf 'wrangle: artifact %s listed but not found\n' "$dist" >&2
            return 1
        fi
        gh release upload "$ref" "$dist" --clobber || return 1
    done
    wrangle_attach_metadata_zip "$ref" || return 1
    wrangle_publish_release "$ref"
}

main() {
    case "${1:-}" in
        run)               wrangle_run ;;
        attach)            wrangle_attach_release ;;
        attach-unattested) wrangle_attach_unattested ;;
        *) printf 'Usage: %s {run|attach|attach-unattested}\n' "${0##*/}" >&2; return 2 ;;
    esac
}

# Run on direct execution; sourcing (the unit tests) exposes the helpers only.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
