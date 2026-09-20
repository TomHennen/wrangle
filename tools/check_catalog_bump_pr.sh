#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external tool/image names

# tools/check_catalog_bump_pr.sh — verify that a change is exactly the
# curated-digest bump tools/bump_catalog_to_latest.sh would produce. Exit 0 means
# verified and nothing else, so the `catalog-bump-verified` check can stand in
# for the per-digest human read (CLAUDE.md, Contributing process).
#
# Verified requires all of: the diff base...head is exactly tools/catalog.json;
# the head catalog passes check_catalog.sh; it differs from base in nothing but
# curated image digests; and a re-run of bump_catalog_to_latest.sh leaves it
# byte-identical — every pinned digest is the registry's current :latest. An
# unreachable registry is not verified.
#
# Run the BASE ref's copy, which `--from-base` does: this script decides what
# counts, so a change that also rewrites the check, the bump script or the
# catalog reader cannot vouch for itself.
#
# Usage: check_catalog_bump_pr.sh <base_ref> <head_ref>
#        check_catalog_bump_pr.sh --from-base <base_worktree> <base_ref> <head_ref>
#
# Exit: 0 verified; 1 not verified (a wider diff, a catalog that does not
#       reproduce, or no verifier on the base ref); 2 usage/environment error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CATALOG_REL="tools/catalog.json"
SELF_REL="tools/check_catalog_bump_pr.sh"
CHECK_CATALOG="$SCRIPT_DIR/check_catalog.sh"
BUMP_TO_LATEST="$SCRIPT_DIR/bump_catalog_to_latest.sh"

usage() {
    printf 'Usage: %s <base_ref> <head_ref>\n' "${0##*/}" >&2
    printf '       %s --from-base <base_worktree> <base_ref> <head_ref>\n' "${0##*/}" >&2
}

# catalog_shape <file> — the catalog with every image digest masked, so two
# shapes compare equal iff nothing but digests moved. A capability grant, a
# renamed image or an added tool changes the shape.
catalog_shape() {
    jq -S '.tools |= with_entries(.value.image |= sub("@sha256:[0-9a-f]{64}$"; "@digest"))' "$1"
}

# verify_catalog_bump <work_dir> <base_ref> <head_ref>
verify_catalog_bump() {
    local work="$1" base="$2" head="$3" changed helper

    for helper in "$CHECK_CATALOG" "$BUMP_TO_LATEST"; do
        if [[ ! -x "$helper" ]]; then
            printf 'check_catalog_bump_pr: missing or non-executable helper: %s\n' "$helper" >&2
            return 2
        fi
    done

    # --no-renames keeps --name-only at one path per changed file, which the
    # whole gate rests on.
    changed="$(git -C "$REPO_DIR" diff --name-only --no-renames "$base...$head")" || return 2

    if [[ "$changed" != "$CATALOG_REL" ]]; then
        printf 'check_catalog_bump_pr: NOT VERIFIED — the diff is not %s alone\n' "$CATALOG_REL" >&2
        return 1
    fi

    git -C "$REPO_DIR" show "$base:$CATALOG_REL" >"$work/base.json" || return 2
    git -C "$REPO_DIR" show "$head:$CATALOG_REL" >"$work/head.json" || return 2

    if ! WRANGLE_CATALOG="$work/head.json" "$CHECK_CATALOG"; then
        printf 'check_catalog_bump_pr: NOT VERIFIED — head catalog is not a valid curated catalog\n' >&2
        return 1
    fi

    if ! catalog_shape "$work/base.json" >"$work/base.shape" \
        || ! catalog_shape "$work/head.json" >"$work/head.shape"; then
        printf 'check_catalog_bump_pr: NOT VERIFIED — could not normalize a catalog\n' >&2
        return 1
    fi
    if ! diff -u "$work/base.shape" "$work/head.shape" >&2; then
        printf 'check_catalog_bump_pr: NOT VERIFIED — changes more than curated image digests\n' >&2
        return 1
    fi

    cp "$work/head.json" "$work/reproduced.json"
    if ! WRANGLE_CATALOG="$work/reproduced.json" "$BUMP_TO_LATEST"; then
        printf 'check_catalog_bump_pr: NOT VERIFIED — could not resolve every :latest digest\n' >&2
        return 1
    fi
    if ! diff -u "$work/head.json" "$work/reproduced.json" >&2; then
        printf 'check_catalog_bump_pr: NOT VERIFIED — a pinned digest is not the registry current :latest\n' >&2
        return 1
    fi

    printf 'check_catalog_bump_pr: VERIFIED — %s pins exactly the current :latest digests\n' "$CATALOG_REL"
}

# exec_from_base <base_worktree> <base_ref> <head_ref> — hand the verdict to the
# base ref's own copy, or fail if it ships none.
exec_from_base() {
    local base_check="$1/$SELF_REL"
    if [[ ! -x "$base_check" ]]; then
        printf 'check_catalog_bump_pr: NOT VERIFIED — base ref ships no executable verifier at %s\n' \
            "$base_check" >&2
        return 1
    fi
    exec "$base_check" "$2" "$3"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "${1:-}" == "--from-base" ]]; then
        if [[ "$#" -ne 4 ]]; then
            usage
            exit 2
        fi
        exec_from_base "$2" "$3" "$4"
    fi
    if [[ "$#" -ne 2 ]]; then
        usage
        exit 2
    fi
    work_dir="$(mktemp -d)" || exit 2
    trap 'rm -rf "$work_dir"' EXIT
    verify_catalog_bump "$work_dir" "$1" "$2"
fi
