#!/bin/bash
set -euo pipefail

# lib/tool_banner.sh — Print a visual banner for tool log attribution.
#
# Usage: tool_banner.sh <tool_name>
# Output: Banner to stdout for CI log readability.

if [[ $# -ne 1 ]]; then
    printf 'Usage: tool_banner.sh <tool_name>\n' >&2
    exit 1
fi

printf '\n========================================\n'
printf ' wrangle/%s\n' "$1"
printf '========================================\n'
