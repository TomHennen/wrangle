#!/bin/bash
set -euo pipefail
set -f

# test/tool_image_tags.sh — print the local :test tag of every catalog tool
# image (the tags the test/image bats build), one per line. This is the save
# list the integration setup registers for build_shell.yml's image-cache steps.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CATALOG="$REPO_ROOT/tools/catalog.json"

# catalog_image_dirs <catalog_file> — print the tools/ subdirectory name of
# every entry naming an image (matching check_catalog.sh): the image ref's path
# tail (minus @digest) is the tool's directory and Dockerfile home.
catalog_image_dirs() {
    local file="$1" image ref
    [[ -f "$file" ]] || return 0
    while IFS= read -r image; do
        ref="${image%@*}"
        printf '%s\n' "${ref##*/}"
    done < <(jq -r '.tools[].image // empty' "$file")
}

# tool_image_tag <dir> — the local tag the tool's bats file builds and runs.
tool_image_tag() {
    if [[ "$1" == wrangle-* ]]; then
        printf '%s:test\n' "$1"
    else
        printf 'wrangle-%s:test\n' "$1"
    fi
}

list_tool_image_tags() {
    local dir
    while IFS= read -r dir; do
        tool_image_tag "$dir"
    done < <(catalog_image_dirs "$CATALOG")
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    list_tool_image_tags
fi
