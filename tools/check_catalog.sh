#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external tool/field names

# tools/check_catalog.sh — static, network-free validator for wrangle's curated
# tool catalog (tools/catalog.json). The footgun linter from
# docs/tool_container_design.md §8: keep the catalog honest so a mutable or
# off-namespace image reference can't pass CI green.
#
# For every tool it asserts: the file is valid JSON, a `kind` is declared, and a
# declared `network`/`secret` is from the allowed, default-closed set. For every
# `delivery: image` entry it additionally asserts the image is digest-pinned
# (@sha256: + 64 hex, never a bare tag / :latest / @latest) on the curated
# registry namespace ghcr.io/tomhennen/wrangle/<name>; a digest-pinned image on a
# genuinely different host is allowed as a fallback, but anything on the curated
# host that is off-namespace is rejected.
#
# Catalog path: $WRANGLE_CATALOG, else the catalog beside this script.
#
# Exit: 0 clean, 1 a violation (offending tool+field printed), 2 usage/env error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NETWORK_ALLOWED_RE='^(none|egress)$'
SECRET_NAME_RE='^[a-z][a-z0-9-]*$'
IMAGE_STRICT_RE='^ghcr\.io/tomhennen/wrangle/[a-z0-9._-]+@sha256:[0-9a-f]{64}$'
IMAGE_GHCR_RE='^ghcr\.io/'
IMAGE_DIGEST_RE='^[a-z0-9._-]+(:[0-9]+)?(/[a-z0-9._-]+)*@sha256:[0-9a-f]{64}$'

# validate_catalog <catalog_file> — print one line per violation to stderr.
# Returns 0 clean, 1 any violation. A malformed/unparseable catalog is itself a
# violation (1), not an env error.
validate_catalog() {
    local file="$1" rc=0

    if [[ ! -f "$file" ]]; then
        printf 'check_catalog: catalog not found: %s\n' "$file" >&2
        return 1
    fi
    if ! jq -e . "$file" >/dev/null 2>&1; then
        printf 'check_catalog: %s is not valid JSON\n' "$file" >&2
        return 1
    fi

    local tool kind delivery image network secret
    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue

        kind="$(jq -r --arg t "$tool" '.tools[$t].kind // empty' "$file")"
        if [[ -z "$kind" ]]; then
            printf 'check_catalog: %s: missing kind\n' "$tool" >&2
            rc=1
        fi

        network="$(jq -r --arg t "$tool" '.tools[$t].network // empty' "$file")"
        if [[ -n "$network" ]] && [[ ! "$network" =~ $NETWORK_ALLOWED_RE ]]; then
            printf 'check_catalog: %s: invalid network value: %s\n' "$tool" "$network" >&2
            rc=1
        fi

        secret="$(jq -r --arg t "$tool" '.tools[$t].secret // empty' "$file")"
        if [[ -n "$secret" ]] && [[ ! "$secret" =~ $SECRET_NAME_RE ]]; then
            printf 'check_catalog: %s: invalid secret name: %s\n' "$tool" "$secret" >&2
            rc=1
        fi

        delivery="$(jq -r --arg t "$tool" '.tools[$t].delivery // empty' "$file")"
        if [[ "$delivery" == "image" ]]; then
            image="$(jq -r --arg t "$tool" '.tools[$t].image // empty' "$file")"
            if [[ -z "$image" ]]; then
                printf 'check_catalog: %s: delivery: image but no image\n' "$tool" >&2
                rc=1
            elif [[ "$image" =~ $IMAGE_STRICT_RE ]]; then
                : # curated, digest-pinned — ok
            elif [[ "$image" =~ $IMAGE_GHCR_RE ]]; then
                printf 'check_catalog: %s: image off the curated namespace ghcr.io/tomhennen/wrangle/: %s\n' "$tool" "$image" >&2
                rc=1
            elif [[ "$image" =~ $IMAGE_DIGEST_RE ]]; then
                : # non-curated host, still digest-pinned — ok
            else
                printf 'check_catalog: %s: image not digest-pinned (needs @sha256:<64hex>): %s\n' "$tool" "$image" >&2
                rc=1
            fi
        fi
    done < <(jq -r '.tools // {} | keys[]' "$file")

    return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -gt 0 ]]; then
        printf 'Usage: %s   (catalog: WRANGLE_CATALOG env, else %s/catalog.json)\n' "${0##*/}" "$SCRIPT_DIR" >&2
        exit 2
    fi
    catalog="${WRANGLE_CATALOG:-$SCRIPT_DIR/catalog.json}"
    if validate_catalog "$catalog"; then
        printf 'check_catalog: %s is valid\n' "$catalog"
        exit 0
    fi
    exit 1
fi
