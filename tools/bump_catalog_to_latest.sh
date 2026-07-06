#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external tool names

# tools/bump_catalog_to_latest.sh — repoint every curated first-party catalog
# entry to its current registry `:latest` digest. The batch driver behind the
# post-publish auto-bump (docs/tool_container_design.md §11): it resolves
# `:latest` for each ghcr.io/tomhennen/wrangle/* image entry and
# applies bump_catalog_digest.sh to any that drifted. Adopter-override entries
# (a foreign namespace) are skipped — wrangle owns only its own images.
#
# Catalog path: $WRANGLE_CATALOG, else the catalog beside this script.
#
# Exit: 0 done (catalog updated in place, or already current — idempotent),
#       2 a registry backend failure for some entry (that entry left unchanged;
#         any resolvable entry is still bumped).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/registry.sh
source "$SCRIPT_DIR/../lib/registry.sh"

# bump_catalog_to_latest <catalog_file> — 0 done, 2 a backend error.
bump_catalog_to_latest() {
    local file="$1" backend_err=0 bumped=0 checked=0
    local tool image imagename pinned resolved

    if [[ ! -f "$file" ]]; then
        printf 'bump_catalog_to_latest: catalog not found: %s\n' "$file" >&2
        return 2
    fi
    if ! jq -e . "$file" >/dev/null 2>&1; then
        printf 'bump_catalog_to_latest: %s is not valid JSON\n' "$file" >&2
        return 2
    fi

    while IFS=$'\t' read -r tool image; do
        [[ -z "$tool" ]] && continue
        imagename="${image%@sha256:*}"
        pinned="${image##*@}"

        is_curated_image "$imagename" || continue
        checked=$((checked + 1))

        if ! resolved="$(resolve_latest_digest "$imagename")"; then
            printf 'bump_catalog_to_latest: %s: could not resolve %s:latest\n' "$tool" "$imagename" >&2
            backend_err=1
            continue
        fi
        [[ "$resolved" == "$pinned" ]] && continue

        if ! WRANGLE_CATALOG="$file" "$SCRIPT_DIR/bump_catalog_digest.sh" "$tool" "$resolved"; then
            printf 'bump_catalog_to_latest: %s: bump to %s failed\n' "$tool" "$resolved" >&2
            backend_err=1
            continue
        fi
        bumped=$((bumped + 1))
    done < <(jq -r '.tools // {} | to_entries[]
        | select(.value.image != null)
        | [.key, .value.image] | @tsv' "$file")

    printf 'bump_catalog_to_latest: bumped %d of %d curated image digest(s)\n' "$bumped" "$checked"
    [[ "$backend_err" -eq 1 ]] && return 2
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -gt 0 ]]; then
        printf 'Usage: %s   (catalog: WRANGLE_CATALOG env, else %s/catalog.json)\n' "${0##*/}" "$SCRIPT_DIR" >&2
        exit 2
    fi
    bump_catalog_to_latest "${WRANGLE_CATALOG:-$SCRIPT_DIR/catalog.json}"
fi
