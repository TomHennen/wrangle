#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external field/tool names

# lib/read_catalog.sh — read one field of one tool from wrangle's curated tool
# catalog (tools/catalog.yaml, docs/tool_container_design.md §3.6).
#
# The catalog is wrangle-maintained and has a fixed, flat shape — a top-level
# `tools:` map of `<name>:` entries, each a block of `<field>: <scalar>` lines
# at a constant indent — so a strict line scanner reads it without a YAML
# dependency in the security-critical orchestrator. It is NOT a general YAML
# parser: it accepts only that shape (block-style maps, scalar values, `#`
# comments) and a malformed entry simply yields no value.
#
# Usage: read_catalog.sh <catalog_file> <tool> <field>
# Prints the scalar value (trailing inline `# comment` and surrounding quotes
# stripped) on stdout, or nothing if the tool or field is absent. Always exits 0
# unless its arguments are wrong — an absent entry is a normal "not in catalog".

read_catalog_field() {
    local file="$1" want_tool="$2" want_field="$3"
    [[ -f "$file" ]] || return 0

    local in_tools=0 cur_tool="" line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip a full-line comment and skip blank lines.
        case "$line" in
            '#'*|'') continue ;;
        esac
        # Top-level `tools:` opens the map; any other column-0 key closes it.
        if [[ "$line" =~ ^[^[:space:]] ]]; then
            if [[ "$line" == tools:* ]]; then in_tools=1; else in_tools=0; fi
            cur_tool=""
            continue
        fi
        [[ "$in_tools" -eq 1 ]] || continue
        # A two-space-indented `name:` (no further-indented value) names an entry.
        if [[ "$line" =~ ^[[:space:]][[:space:]]([a-z][a-z0-9_-]*):[[:space:]]*$ ]]; then
            cur_tool="${BASH_REMATCH[1]}"
            continue
        fi
        # A four-space-indented `field: value` line within the wanted entry.
        if [[ "$cur_tool" == "$want_tool" ]] \
            && [[ "$line" =~ ^[[:space:]][[:space:]][[:space:]][[:space:]]([a-z][a-z0-9_-]*):[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            if [[ "$key" == "$want_field" ]]; then
                # Strip an inline comment (value has no `#`), then quotes/space.
                val="${val%%#*}"
                val="${val%"${val##*[![:space:]]}"}"
                val="${val#\"}"; val="${val%\"}"
                val="${val#\'}"; val="${val%\'}"
                printf '%s' "$val"
                return 0
            fi
        fi
    done < "$file"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -ne 3 ]]; then
        printf 'Usage: %s <catalog_file> <tool> <field>\n' "${0##*/}" >&2
        exit 2
    fi
    read_catalog_field "$1" "$2" "$3"
fi
