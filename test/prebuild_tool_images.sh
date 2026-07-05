#!/bin/bash
set -euo pipefail
set -f

# test/prebuild_tool_images.sh — the catalog-derived tool-image set, under the
# tags the test/image bats expect. `list` prints the tags (the image-cache
# save list); no argument concurrently builds them so serial bats runs hit the
# layer cache. No-op without a docker daemon; each build is best-effort (a
# failure leaves that image cold and its bats build as before).

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

# list_tool_image_tags — one tag per catalog image, the image-cache save list.
list_tool_image_tags() {
    local dir
    while IFS= read -r dir; do
        prebuild_image_tag "$dir"
    done < <(catalog_image_dirs "$CATALOG")
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

    # Lets the image bats' setup_file skip its own build when the prebuilt
    # tag is present (wrangle_prebuilt_image in test/lib/image_test_harness.sh).
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf 'WRANGLE_TOOL_IMAGES_PREBUILT=1\n' >> "$GITHUB_ENV"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        '')   prebuild_tool_images ;;
        list) list_tool_image_tags ;;
        *)
            printf 'Usage: %s [list]\n' "${0##*/}" >&2
            exit 2
            ;;
    esac
fi
