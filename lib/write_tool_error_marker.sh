#!/bin/bash
set -euo pipefail
set -f

# lib/write_tool_error_marker.sh — write the action-pattern tool-error
# marker consumed by lib/check_results.sh. Source-only; see SPEC.md
# §Tool-error marker contract.

wrangle_write_tool_error_marker() {
    local metadata_dir="$1"
    local message="$2"
    mkdir -p "$metadata_dir"
    printf '%s\n' "$message" > "$metadata_dir/error"
}
