#!/bin/bash
set -euo pipefail
set -f

# tools/bump_catalog_digest.sh — repoint one curated tool's image to a new
# @sha256: digest in tools/catalog.json, preserving its registry namespace. The
# catalog analog of bump_action_pins.sh: the one-command fix when
# check_catalog_freshness.sh reports an entry behind :latest.
#
# Catalog path: $WRANGLE_CATALOG, else the catalog beside this script.
#
# Usage: bump_catalog_digest.sh <tool> <digest>      # digest: sha256:<64 hex>
#
# Exit: 0 written (or already current — idempotent), 2 bad usage / unknown tool /
#       non-image entry / bad digest / unreadable catalog.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/read_catalog.sh
source "$SCRIPT_DIR/../lib/read_catalog.sh"

DIGEST_RE='^sha256:[0-9a-f]{64}$'

# bump_catalog_digest <catalog_file> <tool> <digest> — atomically set the tool's
# image to <namespace>@<digest>. Returns 0 on success or no-op, 2 on any error.
bump_catalog_digest() {
    local file="$1" tool="$2" digest="$3"

    if [[ ! "$digest" =~ $DIGEST_RE ]]; then
        printf 'bump_catalog_digest: digest must be sha256:<64 hex>, got: %s\n' "$digest" >&2
        return 2
    fi
    if [[ ! -f "$file" ]] || ! jq -e . "$file" >/dev/null 2>&1; then
        printf 'bump_catalog_digest: catalog missing or not valid JSON: %s\n' "$file" >&2
        return 2
    fi

    local kind image
    kind="$(read_catalog_field "$file" "$tool" kind)"
    image="$(read_catalog_field "$file" "$tool" image)"
    if [[ -z "$kind" && -z "$image" ]]; then
        printf 'bump_catalog_digest: unknown tool: %s\n' "$tool" >&2
        return 2
    fi
    if [[ -z "$image" ]]; then
        printf 'bump_catalog_digest: %s is not an image tool\n' "$tool" >&2
        return 2
    fi

    local namespace="${image%@sha256:*}" new="${image%@sha256:*}@${digest}"
    if [[ "$namespace" == "$image" ]]; then
        printf 'bump_catalog_digest: %s image is not digest-pinned: %s\n' "$tool" "$image" >&2
        return 2
    fi
    if [[ "$new" == "$image" ]]; then
        return 0  # idempotent — already at this digest
    fi

    # Sibling tempfile + atomic mv: $TMPDIR is often a different mount where mv
    # degrades to copy+unlink.
    local tmp
    tmp="$(mktemp "$file.XXXXXX")"
    trap 'rm -f "${tmp:-}"' EXIT INT TERM
    jq --arg t "$tool" --arg img "$new" '.tools[$t].image = $img' "$file" >"$tmp"
    mv "$tmp" "$file"
    printf 'bump_catalog_digest: %s -> %s\n' "$tool" "$new"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -ne 2 ]]; then
        printf 'Usage: %s <tool> <digest>\n' "${0##*/}" >&2
        exit 2
    fi
    bump_catalog_digest "${WRANGLE_CATALOG:-$SCRIPT_DIR/catalog.json}" "$1" "$2"
fi
