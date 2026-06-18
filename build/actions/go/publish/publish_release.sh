#!/bin/bash
# Create the GitHub Release for a tag (if absent) and upload the artifacts
# wrangle attested: the goreleaser archives, checksums.txt, and one signed
# VSA bundle per archive. goreleaser builds with --skip=publish, so wrangle
# owns the Release — only artifacts it attests ship, and nothing not covered
# by provenance (Docker images, Homebrew taps, deb/rpm) is published here.
#
# Usage: publish_release.sh <tag> <dist-dir> <dist-files-json> <bundles-dir>
#
#   tag:             the release tag (goreleaser version output)
#   dist-dir:        directory holding the archives + checksums.txt
#   dist-files-json: JSON array of archive basenames (the build's dist-files)
#   bundles-dir:     directory holding the <archive>.intoto.jsonl bundles

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

# Collect release asset paths into WRANGLE_ASSETS: each archive named in the
# dist-files JSON array, the checksums file, and every *.intoto.jsonl bundle.
# Fails closed if an expected archive or checksums file is missing.
wrangle_collect_assets() {
    local dist_dir="$1" dist_files_json="$2" bundles_dir="$3"
    WRANGLE_ASSETS=()

    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ ! -f "$dist_dir/$f" ]]; then
            printf 'wrangle: dist file not found: %s/%s\n' "$dist_dir" "$f" >&2
            return 1
        fi
        WRANGLE_ASSETS+=("$dist_dir/$f")
    done < <(printf '%s' "$dist_files_json" | jq -r '.[]')

    if [[ ! -f "$dist_dir/checksums.txt" ]]; then
        printf 'wrangle: checksums.txt not found in %s\n' "$dist_dir" >&2
        return 1
    fi
    WRANGLE_ASSETS+=("$dist_dir/checksums.txt")

    # Enumerate via a temp file, not a process substitution, so a find that
    # dies mid-traversal fails closed (same pattern as actions/verify).
    local listing bundle
    listing="$(mktemp "${RUNNER_TEMP:-/tmp}/bundles.XXXXXX")"
    if ! find "$bundles_dir" -type f -name '*.intoto.jsonl' -print0 | sort -z > "$listing"; then
        rm -f "$listing"
        printf 'wrangle: failed to enumerate bundles under %s\n' "$bundles_dir" >&2
        return 1
    fi
    while IFS= read -r -d '' bundle; do
        WRANGLE_ASSETS+=("$bundle")
    done < "$listing"
    rm -f "$listing"

    if [[ "${#WRANGLE_ASSETS[@]}" -eq 0 ]]; then
        printf 'wrangle: no release assets collected\n' >&2
        return 1
    fi
}

# Create the release if it does not exist, then upload every asset.
# Idempotent: --clobber overwrites assets on a re-run.
wrangle_publish() {
    local tag="$1"; shift
    if ! gh release view "$tag" >/dev/null 2>&1; then
        gh release create "$tag" --title "$tag" --generate-notes
    fi
    gh release upload "$tag" "$@" --clobber
}

main() {
    if [[ $# -ne 4 ]]; then
        printf 'Usage: %s <tag> <dist-dir> <dist-files-json> <bundles-dir>\n' "$0" >&2
        return 1
    fi
    local tag="$1" dist_dir="$2" dist_files_json="$3" bundles_dir="$4"

    # The tag flows into `gh release create/upload`; validate before use.
    if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
        printf 'wrangle: refusing unsafe release tag: %s\n' "$tag" >&2
        return 1
    fi

    local -a WRANGLE_ASSETS
    wrangle_collect_assets "$dist_dir" "$dist_files_json" "$bundles_dir"
    wrangle_publish "$tag" "${WRANGLE_ASSETS[@]}"
}

# Sourcing (the unit tests) exposes the helpers only; direct execution runs main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
