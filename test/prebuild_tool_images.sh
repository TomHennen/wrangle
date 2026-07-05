#!/bin/bash
set -euo pipefail
set -f

# test/prebuild_tool_images.sh — concurrently build every catalog tool image
# under the tag its test/image bats file expects, so those per-file setup
# builds become cache hits. No-op without a docker daemon; each build is
# best-effort (a failure leaves that image cold and its bats build as before).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CATALOG="$REPO_ROOT/tools/catalog.json"

# catalog_image_dirs <catalog_file> — print the tools/ subdirectory name of
# every entry naming an image (with or without delivery: image, matching
# check_catalog.sh): the image ref's path tail (minus @digest) is the tool's
# directory and Dockerfile home.
catalog_image_dirs() {
    local file="$1" image ref
    [[ -f "$file" ]] || return 0
    while IFS= read -r image; do
        ref="${image%@*}"
        printf '%s\n' "${ref##*/}"
    done < <(jq -r '.tools[].image // empty' "$file")
}

# prebuild_image_tag <dir> — the local tag the tool's bats file builds and runs.
prebuild_image_tag() {
    if [[ "$1" == wrangle-* ]]; then
        printf '%s:test\n' "$1"
    else
        printf 'wrangle-%s:test\n' "$1"
    fi
}

_prebuild_one() {
    local dir="$1" dockerfile="$REPO_ROOT/tools/$1/Dockerfile" tag
    if [[ ! -f "$dockerfile" ]]; then
        printf 'prebuild_tool_images: no Dockerfile for catalog image %s\n' "$dir" >&2
        return 0
    fi
    tag="$(prebuild_image_tag "$dir")"
    docker build -q -f "$dockerfile" -t "$tag" "$REPO_ROOT" >/dev/null 2>&1 \
        || printf 'prebuild_tool_images: build failed for %s (cache not warmed)\n' "$dir" >&2
}

prebuild_tool_images() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0

    local dir pids=()
    while IFS= read -r dir; do
        _prebuild_one "$dir" &
        pids+=("$!")
    done < <(catalog_image_dirs "$CATALOG")

    local pid
    for pid in "${pids[@]+"${pids[@]}"}"; do
        wait "$pid"
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    prebuild_tool_images
fi
