#!/bin/bash
# Validates inputs to the container build action and writes normalized
# values to GITHUB_OUTPUT (path, lowercased imagename, shortname for
# artifact namespacing).
#
# Path validation is delegated to lib/validate_path.sh. Registry and
# imagename are checked here against narrow allowlists because they
# are container-specific.
#
# The optional dockerfile sets build-push-action's file + context: empty
# (default) = the <path> subdir is the context; set = the repo root is the
# context, so the Dockerfile can COPY files outside <path>.
#
# Usage: build/actions/container/validate_inputs.sh <path> <registry> <imagename> <cache> [dockerfile]

set -euo pipefail
set -f  # disable globbing — processes external input

if [[ $# -lt 4 || $# -gt 5 ]]; then
    printf 'Usage: %s <path> <registry> <imagename> <cache> [dockerfile]\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
INPUT_REGISTRY="$2"
INPUT_IMAGENAME="$3"
INPUT_CACHE="$4"
INPUT_DOCKERFILE="${5:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shortname.sh
source "$SCRIPT_DIR/../../../lib/shortname.sh"

# Reject any cache value outside the enabled|disabled|isolated|read-only
# allowlist. This is load-bearing for SLSA L3: the reusable workflow passes
# cache=disabled for release builds, and a typo there must fail the build
# loudly rather than silently leave the BuildKit cache on (which would
# downgrade the release build from Build L3 to Build L2). The same
# allowlist constrains the value before resolve_cache.sh maps it to the
# BuildKit cache flags. See docs/SLSA_L3_AUDIT.md Finding 2 and its
# "Should wrangle care about PR-to-PR cache poisoning?" section.
if [[ ! "$INPUT_CACHE" =~ ^(enabled|disabled|isolated|read-only)$ ]]; then
    printf 'Error: invalid cache value: %s (expected enabled, disabled, isolated, or read-only)\n' "$INPUT_CACHE" >&2
    exit 1
fi

"$SCRIPT_DIR/../../../lib/validate_path.sh" "$INPUT_PATH"

# When set, the dockerfile flows into the build context selection (it becomes
# docker/build-push-action's `file`), so it gets the same strict allowlist as
# `path`: relative, no traversal, charset [a-zA-Z0-9_./-].
if [[ -n "$INPUT_DOCKERFILE" ]]; then
    "$SCRIPT_DIR/../../../lib/validate_path.sh" "$INPUT_DOCKERFILE"
fi

if [[ ! "$INPUT_REGISTRY" =~ ^[a-z0-9.-]+$ ]]; then
    printf 'Error: invalid registry: %s\n' "$INPUT_REGISTRY" >&2
    exit 1
fi
# Uppercase is accepted and lowercased below: `github.repository` preserves
# owner case, so an owner like `TomHennen` must normalize, not be rejected.
if [[ ! "$INPUT_IMAGENAME" =~ ^[a-zA-Z0-9./:_-]+$ ]]; then
    printf 'Error: invalid image name: %s\n' "$INPUT_IMAGENAME" >&2
    exit 1
fi

# Select the docker/build-push-action `context` and `file`. Default (no
# dockerfile): the <path> subdirectory is the context, with its own root
# Dockerfile (file empty). With a dockerfile: the repo root is the context,
# and the Dockerfile lives at that subpath — so it can COPY repo-root files.
# `path` still drives shortname/metadata naming either way.
if [[ -z "$INPUT_DOCKERFILE" ]]; then
    BUILD_CONTEXT="{{defaultContext}}:$INPUT_PATH"
    BUILD_FILE=""
else
    BUILD_CONTEXT="{{defaultContext}}"
    BUILD_FILE="$INPUT_DOCKERFILE"
fi

{
    printf 'imagename=%s\n' "${INPUT_IMAGENAME,,}"
    printf 'path=%s\n' "$INPUT_PATH"
    printf 'shortname=%s\n' "$(derive_shortname "$INPUT_PATH")"
    printf 'context=%s\n' "$BUILD_CONTEXT"
    printf 'file=%s\n' "$BUILD_FILE"
} >> "$GITHUB_OUTPUT"
