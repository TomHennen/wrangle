#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external file contents

# lib/merge_catalog.sh — build the effective tool catalog by ADDING an adopter's
# custom tools to wrangle's curated catalog (both share the { "tools": { … } }
# shape). The model is add-only: an adopter may add net-new tools, never override
# a curated one. A custom tool whose name collides with a curated tool is a hard
# error — no shadowing, no field merge, so a custom entry can never attach its
# capabilities to a curated, VSA-signed image. Each custom entry is validated
# standalone and declares its own capabilities; there is no inheritance.
#
# Usage: merge_catalog.sh <curated_catalog> <custom_tools_file>
# Prints the effective catalog on stdout. Exits non-zero (message on stderr) when
# the custom file is not valid JSON, collides with a curated name, or any entry
# fails validation.

# A distinct name from the caller's SCRIPT_DIR — run.sh sources this file and
# then sources more libs relative to its own SCRIPT_DIR.
_MERGE_CATALOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/read_catalog.sh
source "$_MERGE_CATALOG_DIR/read_catalog.sh"
# shellcheck source=lib/catalog_rules.sh
source "$_MERGE_CATALOG_DIR/catalog_rules.sh"

merge_catalog() {
    local curated="$1" custom="$2"
    local curated_json='{"tools":{}}'
    [[ -f "$curated" ]] && curated_json="$(cat "$curated")"

    if ! jq -e '(.tools // {}) | type == "object"' "$custom" >/dev/null 2>&1; then
        printf 'wrangle: custom-tools: not a valid JSON catalog (needs an object "tools"): %s\n' "$custom" >&2
        return 1
    fi

    # Add-only: a name shared with the curated catalog is rejected, never merged.
    local collisions
    collisions="$(jq -rn --argjson c "$curated_json" --slurpfile x "$custom" '
        ($c.tools // {} | keys) as $ck
        | ($x[0].tools // {} | keys)
        | map(select(. as $k | $ck | index($k)))
        | .[]')"
    if [[ -n "$collisions" ]]; then
        printf 'wrangle: custom-tools: name collides with a curated tool (add-only, no override): %s\n' \
            "$(printf '%s' "$collisions" | tr '\n' ' ')" >&2
        return 1
    fi

    local rc=0 tool kind delivery image network secret
    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        if [[ ! "$tool" =~ $CATALOG_TOOL_NAME_RE ]]; then
            printf 'wrangle: custom-tools: invalid tool name: %s\n' "$tool" >&2
            rc=1; continue
        fi

        kind="$(read_catalog_field "$custom" "$tool" kind)"
        if [[ ! "$kind" =~ $CATALOG_KIND_RE ]]; then
            printf 'wrangle: custom-tools: %s: kind must be one of scan, sbom, attest\n' "$tool" >&2
            rc=1
        fi

        network="$(read_catalog_field "$custom" "$tool" network)"
        if [[ -n "$network" ]] && [[ ! "$network" =~ $CATALOG_NETWORK_RE ]]; then
            printf 'wrangle: custom-tools: %s: network must be one of none, egress\n' "$tool" >&2
            rc=1
        fi

        secret="$(read_catalog_field "$custom" "$tool" secret)"
        if [[ -n "$secret" ]] && [[ ! "$secret" =~ $CATALOG_SECRET_NAME_RE ]]; then
            printf 'wrangle: custom-tools: %s: invalid secret name: %s\n' "$tool" "$secret" >&2
            rc=1
        fi

        # A custom tool is always net-new and image-delivered.
        delivery="$(read_catalog_field "$custom" "$tool" delivery)"
        if [[ "$delivery" != "image" ]]; then
            printf 'wrangle: custom-tools: %s: must declare delivery: image\n' "$tool" >&2
            rc=1
        fi

        image="$(read_catalog_field "$custom" "$tool" image)"
        if [[ -z "$image" ]]; then
            printf 'wrangle: custom-tools: %s: must declare a digest-pinned image\n' "$tool" >&2
            rc=1
        elif [[ ! "$image" =~ $CATALOG_IMAGE_DIGEST_RE ]]; then
            printf 'wrangle: custom-tools: %s: image must be digest-pinned (name@sha256:<64hex>): %s\n' "$tool" "$image" >&2
            rc=1
        fi
    done < <(jq -r '.tools // {} | keys[]' "$custom")

    [[ "$rc" -ne 0 ]] && return 1

    jq -n --argjson c "$curated_json" --slurpfile x "$custom" \
        '{ tools: (($c.tools // {}) + ($x[0].tools // {})) }'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -ne 2 ]]; then
        printf 'Usage: %s <curated_catalog> <custom_tools_file>\n' "${0##*/}" >&2
        exit 2
    fi
    merge_catalog "$1" "$2"
fi
