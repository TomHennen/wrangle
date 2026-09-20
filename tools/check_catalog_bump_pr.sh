#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external tool/image names

# tools/check_catalog_bump_pr.sh — decide whether a change is exactly the
# curated-digest bump tools/bump_catalog_to_latest.sh would produce, so it can
# merge without a per-digest human read (CLAUDE.md, Contributing process).
#
# In scope only when the diff base...head is exactly tools/catalog.json. Then
# the head catalog must pass check_catalog.sh, differ from base in nothing but
# curated image digests, and survive a re-run of bump_catalog_to_latest.sh
# byte-identical — every pinned digest is the registry's current :latest.
# Anything else fails, including an unreachable registry.
#
# Invoke the BASE ref's copy: this script decides scope, so a change that also
# rewrites the check, the bump script or the catalog reader is out of scope and
# cannot vouch for itself.
#
# Usage: check_catalog_bump_pr.sh <base_ref> <head_ref>
#
# Exit: 0 verified, or out of scope (normal review applies); 1 in scope but not
#       reproducible; 2 usage/environment error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CATALOG_REL="tools/catalog.json"

# catalog_shape <file> — the catalog with every image digest masked, so two
# shapes compare equal iff nothing but digests moved. A capability grant, a
# renamed image or an added tool changes the shape.
catalog_shape() {
    jq -S '.tools |= with_entries(.value.image |= sub("@sha256:[0-9a-f]{64}$"; "@digest"))' "$1"
}

# verify_catalog_bump <work_dir> <base_ref> <head_ref>
verify_catalog_bump() {
    local work="$1" base="$2" head="$3" changed

    changed="$(git -C "$REPO_DIR" diff --name-only "$base...$head")" || return 2

    if [[ "$changed" != "$CATALOG_REL" ]]; then
        printf 'check_catalog_bump_pr: not a %s-only change; normal review applies\n' "$CATALOG_REL"
        return 0
    fi

    git -C "$REPO_DIR" show "$base:$CATALOG_REL" >"$work/base.json" || return 2
    git -C "$REPO_DIR" show "$head:$CATALOG_REL" >"$work/head.json" || return 2

    if ! WRANGLE_CATALOG="$work/head.json" "$SCRIPT_DIR/check_catalog.sh"; then
        printf 'check_catalog_bump_pr: head catalog is not a valid curated catalog\n' >&2
        return 1
    fi

    if ! catalog_shape "$work/base.json" >"$work/base.shape" \
        || ! catalog_shape "$work/head.json" >"$work/head.shape"; then
        printf 'check_catalog_bump_pr: could not normalize a catalog\n' >&2
        return 1
    fi
    if ! diff -u "$work/base.shape" "$work/head.shape" >&2; then
        printf 'check_catalog_bump_pr: changes more than curated image digests\n' >&2
        return 1
    fi

    cp "$work/head.json" "$work/reproduced.json"
    if ! WRANGLE_CATALOG="$work/reproduced.json" "$SCRIPT_DIR/bump_catalog_to_latest.sh"; then
        printf 'check_catalog_bump_pr: could not resolve every :latest digest; unverified\n' >&2
        return 1
    fi
    if ! diff -u "$work/head.json" "$work/reproduced.json" >&2; then
        printf 'check_catalog_bump_pr: a pinned digest is not the registry current :latest\n' >&2
        return 1
    fi

    printf 'check_catalog_bump_pr: verified — %s pins exactly the current :latest digests\n' "$CATALOG_REL"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -ne 2 ]]; then
        printf 'Usage: %s <base_ref> <head_ref>\n' "${0##*/}" >&2
        exit 2
    fi
    work_dir="$(mktemp -d)" || exit 2
    trap 'rm -rf "$work_dir"' EXIT
    verify_catalog_bump "$work_dir" "$1" "$2"
fi
