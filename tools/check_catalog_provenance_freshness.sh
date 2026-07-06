#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external tool names

# tools/check_catalog_provenance_freshness.sh — checks each curated tool image in
# tools/catalog.json was built from the current tool source, by reading the
# image's signed SLSA provenance for its build commit and diffing that commit
# against HEAD. A release gate: needs the network and full history (fetch-depth: 0).
#
# Catalog path: $WRANGLE_CATALOG, else the catalog beside this script.
#
# Exit: 0 all built from current source; 1 a source changed since build, or the
#       provenance binds no wrangle commit; 2 backend unreachable (no provenance
#       lands here, fail-closed) or gh/jq/git missing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/read_catalog.sh
source "$SCRIPT_DIR/../lib/read_catalog.sh"
# shellcheck source=../lib/registry.sh
source "$SCRIPT_DIR/../lib/registry.sh"
# shellcheck source=../lib/verify_image_vsa.sh
source "$SCRIPT_DIR/../lib/verify_image_vsa.sh"

PROVENANCE_PREDICATE_TYPE='https://slsa.dev/provenance/v1'
COMMIT_RE='^[0-9a-f]{40}$'
# A build commit is trusted only from a resolvedDependency on wrangle's own repo.
WRANGLE_SOURCE_URI_PREFIX='git+https://github.com/tomhennen/wrangle@'
# Whole tools/ so a binary built from a sibling package counts; minus the catalog
# file, so a digest bump can't flag its own image stale.
PROVENANCE_DIFF_PATHS=(tools lib ':(exclude)tools/catalog.json')

# provenance_build_commit <image> — print the single wrangle build commit from
# <image>'s signed provenance. Returns 2 on a read failure, 1 if no single
# unambiguous commit is bound.
provenance_build_commit() {
    local image="$1" json rc=0 commits
    local timeout_s="${WRANGLE_VERIFY_TIMEOUT:-120}"
    json="$(mktemp)"
    wrangle_retry_once "$json" timeout "$timeout_s" gh attestation verify "oci://${image}" \
        --repo TomHennen/wrangle \
        --bundle-from-oci \
        --cert-identity-regex "$WRANGLE_CONTAINER_SIGNER_REGEX" \
        --cert-oidc-issuer "$WRANGLE_VSA_OIDC_ISSUER" \
        --predicate-type "$PROVENANCE_PREDICATE_TYPE" \
        --format json || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        rm -f "$json"
        return 2
    fi

    # gh verified the signature + identity; the build commit is ours to read.
    commits="$(jq -r --arg p "$WRANGLE_SOURCE_URI_PREFIX" '
        [ .[].verificationResult.statement.predicate.buildDefinition.resolvedDependencies[]?
          | select((.uri // "" | ascii_downcase) | startswith($p))
          | .digest.gitCommit // empty ]
        | unique | .[]' < "$json" 2>/dev/null)" || { rm -f "$json"; return 2; }
    rm -f "$json"

    if [[ "$(printf '%s' "$commits" | grep -c .)" -ne 1 ]]; then
        return 1
    fi
    [[ "$commits" =~ $COMMIT_RE ]] || return 1
    printf '%s' "$commits"
}

# check_provenance_freshness <catalog_file> — 0 all fresh, 1 a stale/unbound
# image, 2 backend/env error.
check_provenance_freshness() {
    local file="$1" rc=0 stale=0 backend_err=0
    local tool image imagename commit checked=0 repo_root

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
        image="$(read_catalog_field "$file" "$tool" image)"
        [[ -n "$image" ]] || continue
        imagename="${image%@sha256:*}"

        # Skip adopter-override entries — not wrangle-signed.
        is_curated_image "$imagename" || continue
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

        # git diff --quiet: 0 no change, 1 changed, >1 error.
        local diff_rc=0
        git -C "$repo_root" diff --quiet "$commit" HEAD -- "${PROVENANCE_DIFF_PATHS[@]}" 2>/dev/null || diff_rc=$?
        case "$diff_rc" in
            0) ;;
            1)
                printf 'check_catalog_provenance_freshness: %s: source changed since the pinned image was built at %s — republish, then bump\n' "$tool" "${commit:0:12}" >&2
                stale=1 ;;
            *)
                printf 'check_catalog_provenance_freshness: %s: could not diff against build commit %s\n' "$tool" "${commit:0:12}" >&2
                backend_err=1 ;;
        esac
    done < <(jq -r '.tools // {} | keys[]' "$file")

    # A confirmed stale (1) must not be masked by another tool's backend error (2).
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
