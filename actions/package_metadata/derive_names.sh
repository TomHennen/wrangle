#!/bin/bash
# Emit the per-build packaging artifact names to $GITHUB_OUTPUT.
# Runs from the wrangle checkout so it can source lib/shortname.sh.
# Usage: derive_names.sh <build-type> <shortname> [<path>]

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shortname.sh
source "$SCRIPT_DIR/../../lib/shortname.sh"

main() {
    if [[ $# -lt 2 || $# -gt 3 ]]; then
        printf 'Usage: %s <build-type> <shortname> [<path>]\n' "$0" >&2
        exit 1
    fi
    local type="$1" shortname="$2" path="${3:-}"

    if [[ -z "$shortname" && -n "$path" ]]; then
        shortname="$(derive_shortname "$path")"
    fi

    # Reject any path separator or shell metachar smuggled into a name.
    if [[ -n "$shortname" && ! "$shortname" =~ ^[A-Za-z0-9._-]+$ ]]; then
        printf 'Error: invalid shortname: %s\n' "$shortname" >&2
        exit 1
    fi
    if [[ ! "$type" =~ ^[a-z]+$ ]]; then
        printf 'Error: invalid build type: %s\n' "$type" >&2
        exit 1
    fi

    if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
        printf 'Error: GITHUB_OUTPUT not set; cannot emit names\n' >&2
        exit 1
    fi

    {
        printf 'dist=%s\n' "$(artifact_name "${type}-dist" "$shortname")"
        printf 'scan=%s\n' "$(artifact_name "${type}-scan" "$shortname")"
        printf 'checks=%s\n' "$(artifact_name "${type}-checks" "$shortname")"
        printf 'metadata=%s\n' "$(artifact_name "${type}-metadata" "$shortname")"
        printf 'metadata-pre=%s\n' "$(artifact_name "${type}-premeta" "$shortname")"
        printf 'provenance-bundle=%s\n' "$(artifact_name "${type}-provenance-bundle" "$shortname")"
        printf 'metadata-dir=%s\n' "$(metadata_dir "$type" "$shortname")"
        printf 'shortname=%s\n' "$shortname"
    } >> "$GITHUB_OUTPUT"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
