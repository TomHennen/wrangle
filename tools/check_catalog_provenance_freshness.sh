#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external tool names

# tools/check_catalog_provenance_freshness.sh — provenance-based
# "built-from-current-source" freshness for the curated image entries in
# tools/catalog.json. The true docs/tool_container_design.md §11 guarantee, and
# the one check_catalog_freshness.sh's adoption-lag compare deliberately leaves
# open: it proves the catalog tracks the published :latest, NOT that the pinned
# digest was built from the tool's CURRENT source.
#
# For each curated `delivery: image` entry it reads the pinned image's SLSA build
# provenance via `gh attestation verify`, pinned to wrangle's container
# build+publish signer identity (the same trust anchor lib/verify_image_vsa.sh
# uses — single-sourced here), takes the source commit the image was built from,
# and asserts that commit is an ancestor of HEAD whose tool source is unchanged
# up to HEAD. The diff set is the image's build inputs: the tool dir, lib/, and
# the shared tools/go.mod + tools/go.sum the binary is compiled from
# (.github/workflows/local_publish_images.yml builds the context from those). A
# go.mod-only tool-version bump that never re-published the image is exactly the
# stale-but-green-with-the-signing-token hole the adoption-lag check cannot see.
#
# This is THE gate for the containerized signing path: a stale toolbox image is
# still validly attested, so the pull-time VSA gate (verify_image_vsa) passes it;
# only source-freshness catches a stale image about to run with the signing token.
#
# Network + full git history — a release gate, never the per-PR path; run with
# fetch-depth: 0 so the build commit is present.
#
# Catalog path: $WRANGLE_CATALOG, else the catalog beside this script.
#
# Exit: 0 every curated image is built from current source,
#       1 a tool's source changed since its pinned image was built (republish +
#         bump needed), or the provenance does not bind a wrangle source commit,
#       2 the registry/attestation backend was unreachable, or gh/jq/git missing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/read_catalog.sh
source "$SCRIPT_DIR/../lib/read_catalog.sh"
# Single-source the signer identity + retry from the pull-time VSA gate so the
# provenance read trusts exactly the identities that gate does.
# shellcheck source=../lib/verify_image_vsa.sh
source "$SCRIPT_DIR/../lib/verify_image_vsa.sh"

PROVENANCE_PREDICATE_TYPE='https://slsa.dev/provenance/v1'
CURATED_PREFIX_RE='^ghcr\.io/tomhennen/wrangle/[a-z][a-z0-9_-]*$'
COMMIT_RE='^[0-9a-f]{40}$'
# The source repo the provenance must name (case-insensitive); a build commit is
# only trusted from a resolvedDependency on wrangle's own repo.
WRANGLE_SOURCE_URI_PREFIX='git+https://github.com/tomhennen/wrangle@'
# Image build inputs, relative to the repo root — what a republish would change.
PROVENANCE_DIFF_SHARED=(lib tools/go.mod tools/go.sum)

# provenance_build_commit <image> — print the single wrangle source commit the
# image's signed build provenance names. Non-zero on a backend failure (gh) or
# when no single, unambiguous wrangle commit is bound.
provenance_build_commit() {
    local image="$1" json rc=0 commits
    json="$(mktemp)"
    wrangle_retry_once "$json" gh attestation verify "oci://${image}" \
        --repo TomHennen/wrangle \
        --bundle-from-oci \
        --cert-identity-regex "$WRANGLE_CONTAINER_SIGNER_REGEX" \
        --cert-oidc-issuer "$WRANGLE_VSA_OIDC_ISSUER" \
        --predicate-type "$PROVENANCE_PREDICATE_TYPE" \
        --format json || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        rm -f "$json"
        return 2  # backend/attestation read failed
    fi

    # gh bound the signature + identity; the source-repo binding and the build
    # commit are ours to read. Collect the DISTINCT gitCommit of every resolved
    # dependency on wrangle's repo — exactly one unambiguous commit is required.
    commits="$(jq -r --arg p "$WRANGLE_SOURCE_URI_PREFIX" '
        [ .[].verificationResult.statement.predicate.buildDefinition.resolvedDependencies[]?
          | select((.uri // "" | ascii_downcase) | startswith($p))
          | .digest.gitCommit // empty ]
        | unique | .[]' < "$json" 2>/dev/null)" || { rm -f "$json"; return 2; }
    rm -f "$json"

    if [[ "$(printf '%s' "$commits" | grep -c .)" -ne 1 ]]; then
        return 1  # no, or ambiguous, wrangle source commit
    fi
    [[ "$commits" =~ $COMMIT_RE ]] || return 1
    printf '%s' "$commits"
}

# check_provenance_freshness <catalog_file> — 0 all fresh, 1 a stale/unbound
# image, 2 backend/env error.
check_provenance_freshness() {
    local file="$1" rc=0 stale=0 backend_err=0
    local tool delivery image imagename commit checked=0 repo_root

    if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        printf 'check_catalog_provenance_freshness: gh and jq are required\n' >&2
        return 2
    fi
    if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        printf 'check_catalog_provenance_freshness: not inside a git work tree\n' >&2
        return 2
    fi
    if [[ ! -f "$file" ]]; then
        printf 'check_catalog_provenance_freshness: catalog not found: %s\n' "$file" >&2
        return 2
    fi
    if ! jq -e . "$file" >/dev/null 2>&1; then
        printf 'check_catalog_provenance_freshness: %s is not valid JSON\n' "$file" >&2
        return 2
    fi

    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        delivery="$(read_catalog_field "$file" "$tool" delivery)"
        [[ "$delivery" == "image" ]] || continue
        image="$(read_catalog_field "$file" "$tool" image)"
        imagename="${image%@sha256:*}"

        # Adopter-override entries never live in this catalog; their provenance
        # signer is not wrangle's, so skip them like the adoption-lag check.
        [[ "$imagename" =~ $CURATED_PREFIX_RE ]] || continue
        checked=$((checked + 1))

        local prov_rc=0
        commit="$(provenance_build_commit "$image")" || prov_rc=$?
        if [[ "$prov_rc" -ne 0 ]]; then
            if [[ "$prov_rc" -eq 2 ]]; then
                printf 'check_catalog_provenance_freshness: %s: could not read build provenance for %s\n' "$tool" "$image" >&2
                backend_err=1
            else
                printf 'check_catalog_provenance_freshness: %s: provenance binds no single wrangle source commit for %s\n' "$tool" "$image" >&2
                stale=1
            fi
            continue
        fi

        if ! git -C "$repo_root" cat-file -e "${commit}^{commit}" 2>/dev/null; then
            printf 'check_catalog_provenance_freshness: %s: build commit %s absent — shallow clone? the gate needs fetch-depth: 0\n' "$tool" "${commit:0:12}" >&2
            stale=1
            continue
        fi
        if ! git -C "$repo_root" merge-base --is-ancestor "$commit" HEAD 2>/dev/null; then
            printf 'check_catalog_provenance_freshness: %s: build commit %s is not an ancestor of HEAD (built off-line)\n' "$tool" "${commit:0:12}" >&2
            stale=1
            continue
        fi

        # Stale iff the tool's build inputs changed between the build commit and
        # HEAD. --quiet exits 1 on differences, 0 on none, >1 on error.
        local diff_rc=0
        git -C "$repo_root" diff --quiet "$commit" HEAD -- "tools/$tool" "${PROVENANCE_DIFF_SHARED[@]}" 2>/dev/null || diff_rc=$?
        case "$diff_rc" in
            0) ;;  # built from current source
            1)
                printf 'check_catalog_provenance_freshness: %s: source changed since the pinned image was built at %s — republish, then bump\n' "$tool" "${commit:0:12}" >&2
                stale=1 ;;
            *)
                printf 'check_catalog_provenance_freshness: %s: could not diff against build commit %s\n' "$tool" "${commit:0:12}" >&2
                backend_err=1 ;;
        esac
    done < <(jq -r '.tools // {} | keys[]' "$file")

    # A confirmed stale image (1) is actionable regardless of another tool's
    # reachability and must not be masked by a transient backend error (2).
    if [[ "$stale" -eq 1 ]]; then
        rc=1
    elif [[ "$backend_err" -eq 1 ]]; then
        rc=2
    else
        printf 'check_catalog_provenance_freshness: all %d curated image(s) built from current source\n' "$checked"
    fi
    return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -gt 0 ]]; then
        printf 'Usage: %s   (catalog: WRANGLE_CATALOG env, else %s/catalog.json)\n' "${0##*/}" "$SCRIPT_DIR" >&2
        exit 2
    fi
    check_provenance_freshness "${WRANGLE_CATALOG:-$SCRIPT_DIR/catalog.json}"
fi
