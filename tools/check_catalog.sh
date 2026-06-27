#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external tool/field names

# tools/check_catalog.sh — static, network-free validator for wrangle's curated
# tool catalog (tools/catalog.json). The footgun linter from
# docs/tool_container_design.md §8: keep the catalog honest so a mutable or
# off-namespace image reference can't pass CI green.
#
# For every tool it asserts: the file is valid JSON, a `kind` is declared, the
# `delivery` (if set) is one run.sh recognizes, and a declared `network`/`secret`
# is from the allowed, default-closed set. A `delivery: image` entry must also name
# an image. Any entry naming an `image` (image-delivery or not) must be digest-pinned
# (@sha256: + 64 hex, never a bare tag / :latest / @latest) on the curated namespace
# ghcr.io/tomhennen/wrangle/<tool> — adopter overrides never live in this in-repo
# catalog (§3.6), so a different host or namespace is a violation.
#
# Catalog path: $WRANGLE_CATALOG, else the catalog beside this script.
#
# Exit: 0 clean, 1 a violation (offending tool+field printed), 2 usage/env error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/read_catalog.sh
source "$SCRIPT_DIR/../lib/read_catalog.sh"

NETWORK_ALLOWED_RE='^(none|egress)$'
SECRET_NAME_RE='^[a-z][a-z0-9-]*$'
# Tool segment matches run.sh's tool-name shape, so no leading dot/dash or `..`
# can survive into a registry path.
CURATED_PREFIX='ghcr.io/tomhennen/wrangle/'
IMAGE_STRICT_RE='^ghcr\.io/tomhennen/wrangle/[a-z][a-z0-9_-]*@sha256:[0-9a-f]{64}$'

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

        kind="$(read_catalog_field "$file" "$tool" kind)"
        if [[ -z "$kind" ]]; then
            printf 'check_catalog: %s: missing kind\n' "$tool" >&2
            rc=1
        fi

        network="$(read_catalog_field "$file" "$tool" network)"
        if [[ -n "$network" ]] && [[ ! "$network" =~ $NETWORK_ALLOWED_RE ]]; then
            printf 'check_catalog: %s: invalid network value: %s\n' "$tool" "$network" >&2
            rc=1
        fi

        secret="$(read_catalog_field "$file" "$tool" secret)"
        if [[ -n "$secret" ]] && [[ ! "$secret" =~ $SECRET_NAME_RE ]]; then
            printf 'check_catalog: %s: invalid secret name: %s\n' "$tool" "$secret" >&2
            rc=1
        fi

        # Same allowlist run.sh enforces: empty/adapter/image. A typo'd value must
        # not skip image enforcement and pass green.
        delivery="$(read_catalog_field "$file" "$tool" delivery)"
        case "$delivery" in
            ''|adapter|image) ;;
            *)
                printf 'check_catalog: %s: unrecognized delivery: %s\n' "$tool" "$delivery" >&2
                rc=1 ;;
        esac

        if [[ "$delivery" == "image" ]]; then
            image="$(read_catalog_field "$file" "$tool" image)"
            if [[ -z "$image" ]]; then
                printf 'check_catalog: %s: delivery: image but no image\n' "$tool" >&2
                rc=1
            fi
        fi

        # Any entry that names an image — image-delivery or not (e.g. the
        # attest-toolbox grant the verify path resolves) — must be curated and
        # digest-pinned, so a mutable or off-namespace ref can't pass CI green.
        image="$(read_catalog_field "$file" "$tool" image)"
        if [[ -n "$image" ]]; then
            if [[ "$image" =~ $IMAGE_STRICT_RE ]]; then
                : # curated, digest-pinned — ok
            elif [[ "$image" == "$CURATED_PREFIX"* ]]; then
                printf 'check_catalog: %s: image not digest-pinned (needs ghcr.io/tomhennen/wrangle/<tool>@sha256:<64hex>): %s\n' "$tool" "$image" >&2
                rc=1
            else
                printf 'check_catalog: %s: image off the curated namespace ghcr.io/tomhennen/wrangle/: %s\n' "$tool" "$image" >&2
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
