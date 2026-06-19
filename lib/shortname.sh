#!/bin/bash
set -euo pipefail
set -f
# Shared path-derived shortname logic for all build types. Sourced by the
# per-type metadata scripts/composites so the root-path normalization can't
# drift between go/python/npm/container.
#
# A shortname namespaces per-build artifacts when a repo has several builds
# (e.g. monorepo). For the common root build (path '.') the suffix is empty,
# so artifact names stay clean ('go-metadata', not 'go-metadata-_') and the
# metadata dir is 'metadata/<type>' with no trailing-slash gap.
#
# Usage: source lib/shortname.sh, then call the functions below.

# Derive the shortname from a path: strip leading/trailing slashes, collapse
# repeated slashes, then '/' -> '_'; the repo root '.' -> '' (empty). So
# 'foo/' -> 'foo', '/a//b/' -> 'a_b'. Args: <path>. Prints the shortname
# (possibly empty).
derive_shortname() {
    local path="$1"
    if [[ "$path" == "." ]]; then
        printf ''
        return
    fi
    # Strip leading and trailing slashes so they don't become edge '_'.
    path="${path#"${path%%[!/]*}"}"
    path="${path%"${path##*[!/]}"}"
    # Collapse runs of '/' so 'a//b' doesn't become 'a__b'.
    while [[ "$path" == *//* ]]; do
        path="${path//\/\//\/}"
    done
    printf '%s' "${path////_}"
}

# Join an artifact-name prefix with a shortname: '<prefix>' when the
# shortname is empty (root build), '<prefix>-<shortname>' otherwise.
# Args: <prefix> <shortname>. Prints the artifact name.
artifact_name() {
    local prefix="$1" shortname="$2"
    printf '%s%s' "$prefix" "${shortname:+-$shortname}"
}

# Build the unified metadata dir for a build type: 'metadata/<type>' at the
# repo root, 'metadata/<type>/<shortname>' otherwise. Args: <type> <shortname>.
# Prints the dir path.
metadata_dir() {
    local type="$1" shortname="$2"
    printf 'metadata/%s%s' "$type" "${shortname:+/$shortname}"
}
