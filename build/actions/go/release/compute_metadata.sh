#!/bin/bash
# Computes shortname and version metadata for the Go release composite
# and writes them to $GITHUB_OUTPUT.
#
# - shortname: path-derived identifier for artifact namespacing
#   ('.' -> '_', 'cmd/foo' -> 'cmd_foo').
# - version:   the git tag if the workflow was triggered by a tag push,
#   otherwise "snapshot" (matches what goreleaser uses for its
#   internal version string).
#
# Usage: build/actions/go/release/compute_metadata.sh <input_path>

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

# Pure function: derive shortname from a path. '.' becomes '_';
# 'cmd/foo' becomes 'cmd_foo'. Used for artifact namespacing so a
# repo with multiple Go builds doesn't collide on default names.
# Args: <path>
derive_shortname() {
    local path="$1"
    if [[ "$path" == "." ]]; then
        printf '_\n'
    else
        printf '%s\n' "${path////_}"
    fi
}

# Pure function: read GITHUB_REF and resolve to either "<tag>" (on
# tag pushes) or "snapshot" (everywhere else). Args: none; reads
# GITHUB_REF from the environment.
derive_version() {
    if [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
        printf '%s\n' "${GITHUB_REF#refs/tags/}"
    else
        printf 'snapshot\n'
    fi
}

main() {
    if [[ $# -ne 1 ]]; then
        printf 'Usage: %s <input_path>\n' "$0" >&2
        exit 1
    fi

    if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
        printf 'Error: GITHUB_OUTPUT not set; cannot emit metadata\n' >&2
        exit 1
    fi

    local shortname version
    shortname="$(derive_shortname "$1")"
    version="$(derive_version)"

    printf 'shortname=%s\n' "$shortname" >> "$GITHUB_OUTPUT"
    printf 'version=%s\n' "$version" >> "$GITHUB_OUTPUT"
}

# Sourcing guard: tests source this file to call derive_*() directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
