#!/bin/bash
set -euo pipefail
set -f

# test/prebuild_tool_images.sh — concurrently docker-build every curated tool
# image the catalog declares (delivery: image), warming the shared build-layer
# cache so each image test's setup_file build is a cache hit rather than a fresh
# from-source compile. The set is derived from tools/catalog.json so it can't
# drift from the images the suite actually exercises.
#
# No-op without a docker daemon (the containerized `make integration` path, and
# any runner lacking one). Each build is best-effort and tag-independent: a
# network-bound image (syft's Sigstore verify) that fails leaves the cache cold
# for that one tool, and its test rebuilds as before — never a setup failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CATALOG="$REPO_ROOT/tools/catalog.json"

# catalog_image_dirs <catalog_file> — print the tools/ subdirectory name of each
# delivery: image tool, one per line. The image ref's path tail (minus @digest)
# is the tool's directory and Dockerfile home across the catalog's namespace.
catalog_image_dirs() {
    local file="$1" image ref
    [[ -f "$file" ]] || return 0
    while IFS= read -r image; do
        ref="${image%@*}"
        printf '%s\n' "${ref##*/}"
    done < <(jq -r '.tools[] | select(.delivery=="image") | .image' "$file")
}

# _prebuild_one <dir> — warm the layer cache for tools/<dir>/Dockerfile under a
# throwaway tag. Missing Dockerfile or a failed build only warns; the caller
# stays green so a cold cache degrades to today's behavior.
_prebuild_one() {
    local dir="$1" dockerfile="$REPO_ROOT/tools/$1/Dockerfile"
    if [[ ! -f "$dockerfile" ]]; then
        printf 'prebuild_tool_images: no Dockerfile for catalog image %s\n' "$dir" >&2
        return 0
    fi
    docker build -q -f "$dockerfile" -t "wrangle-prebuild-$dir:cache" "$REPO_ROOT" \
        >/dev/null 2>&1 \
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
