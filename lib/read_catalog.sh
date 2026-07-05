#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external field/tool names

# lib/read_catalog.sh — read one field of one tool from wrangle's curated tool
# catalog (tools/catalog.json), parsed with jq.
#
# The catalog is wrangle-maintained and has a fixed, flat shape, e.g.:
#
#   { "tools": { "osv": { "kind": "scan", "network": "egress" } } }
#
# Usage: read_catalog.sh <catalog_file> <tool> <field>
# Prints the scalar value on stdout, or nothing if the tool or field is absent.
# Tool/field are passed to jq via --arg so they are never interpolated into the
# program. Always exits 0 for normal cases (including an absent entry or a
# missing file); a malformed catalog makes jq fail, so the orchestrator aborts.

read_catalog_field() {
    local file="$1" want_tool="$2" want_field="$3"
    [[ -f "$file" ]] || return 0

    jq -r --arg t "$want_tool" --arg f "$want_field" \
        '.tools[$t][$f] // empty' "$file"
}

# catalog_docker_network <catalog_file> <tool> — echo the tool's catalog network
# as a docker --network value: "egress" gets the default bridge; anything else,
# including an absent field, gets none (a closed network).
catalog_docker_network() {
    case "$(read_catalog_field "$1" "$2" network)" in
        egress) printf 'bridge\n' ;;
        *)      printf 'none\n' ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -ne 3 ]]; then
        printf 'Usage: %s <catalog_file> <tool> <field>\n' "${0##*/}" >&2
        exit 2
    fi
    read_catalog_field "$1" "$2" "$3"
fi
