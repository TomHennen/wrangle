#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external field/tool names

# lib/read_catalog.sh — read one field of one tool from wrangle's curated tool
# catalog (tools/catalog.yaml), parsed with yq (installed by lib/setup.sh).
#
# The catalog is wrangle-maintained and has a fixed, flat shape, e.g.:
#
#   tools:
#     osv:
#       kind: scan
#       network: egress
#     syft:
#       kind: sbom
#
# Usage: read_catalog.sh <catalog_file> <tool> <field>
# Prints the scalar value on stdout, or nothing if the tool or field is absent.
# Tool/field are passed to yq via the environment and read with strenv() so they
# are never interpolated into the expression. Always exits 0 unless arguments are
# wrong or the file is unreadable — an absent entry is a normal "not in catalog".

read_catalog_field() {
    local file="$1" want_tool="$2" want_field="$3"
    [[ -f "$file" ]] || return 0

    tool="$want_tool" field="$want_field" \
        yq -r '.tools[strenv(tool)][strenv(field)] // ""' "$file"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -ne 3 ]]; then
        printf 'Usage: %s <catalog_file> <tool> <field>\n' "${0##*/}" >&2
        exit 2
    fi
    read_catalog_field "$1" "$2" "$3"
fi
