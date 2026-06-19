#!/bin/bash
# Computes shortname, version, and metadata-dir for the Go build
# composites and writes them to $GITHUB_OUTPUT. Shared by checks/
# and release/ — call from either; both need shortname-derived paths.
#
# - shortname:    path-derived identifier for artifact namespacing
#                 ('.' -> '', 'cmd/foo' -> 'cmd_foo').
# - version:      the git tag if the workflow was triggered by a tag
#                 push, otherwise "snapshot" (matches what goreleaser
#                 uses for its internal version string).
# - metadata-dir: "metadata/go[/<shortname>]" — where the composite
#                 writes sbom.spdx.json / govulncheck.json. The
#                 calling workflow uses this path for upload-artifact.
#
# Usage: build/actions/go/compute_metadata.sh <input_path>

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shortname.sh
source "$SCRIPT_DIR/../../../lib/shortname.sh"

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

    {
        printf 'shortname=%s\n' "$shortname"
        printf 'version=%s\n' "$version"
        printf 'metadata-dir=%s\n' "$(metadata_dir go "$shortname")"
    } >> "$GITHUB_OUTPUT"
}

# Sourcing guard: tests source this file to call derive_*() directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
