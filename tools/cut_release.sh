#!/bin/bash
set -euo pipefail
set -f

# cut_release.sh — cut a wrangle release tag (cut-release runbook, Phase 5).
#
# Usage: cut_release.sh <version> <notes-file> [--target <sha>]
#          e.g. cut_release.sh v0.4.0 release-notes.md
#
# The tag is immutable once created and there is no undo, so every precondition
# is checked BEFORE `gh release create` and any failure aborts without tagging:
#
#   1. version is vX.Y.Z (goreleaser needs a semver-parseable tag)
#   2. the tag does not already exist, locally or on the remote
#   3. the notes file exists and is non-empty (never --generate-notes: the runbook
#      wants benefit-first prose, not an auto-changelog)
#   4. the target commit is on origin/main
#   5. the Release Gate workflow is green ON THAT COMMIT — dispatched here and
#      polled, because the gate is the only thing that proves the pins and the
#      curated tool-image digests are release-worthy, and a local run cannot
#      prove it (a stale or shallow checkout yields a confident false green)
#   6. the operator confirms, interactively, with the version
#
# It does NOT write the release notes and it does NOT decide to release: the tag
# is the owner's call.
#
# Exit: 0 released, 1 a precondition failed (nothing tagged), 2 usage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${WRANGLE_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
GATE_WORKFLOW="${WRANGLE_RELEASE_GATE:-release_gate.yml}"

wrangle_die() { printf 'cut_release: %s\n' "$1" >&2; return 1; }

wrangle_check_version() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || wrangle_die "version must be vX.Y.Z (goreleaser needs semver), got: $1"
}

wrangle_check_tag_free() {
    local v="$1"
    if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$v" >/dev/null 2>&1; then
        wrangle_die "tag $v already exists locally — tags are immutable, refusing"
    fi
    if git -C "$REPO_ROOT" ls-remote --exit-code --tags origin "$v" >/dev/null 2>&1; then
        wrangle_die "tag $v already exists on origin — tags are immutable, refusing"
    fi
}

# Hand-written, benefit-first prose. An empty file is a wiring error, not a
# release with no notes.
wrangle_check_notes() {
    local f="$1"
    [[ -f "$f" ]] || wrangle_die "notes file not found: $f"
    [[ -s "$f" ]] || wrangle_die "notes file is empty: $f"
    [[ -n "$(tr -d '[:space:]' < "$f")" ]] || wrangle_die "notes file is whitespace only: $f"
}

wrangle_check_target_on_main() {
    local sha="$1"
    git -C "$REPO_ROOT" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main
    git -C "$REPO_ROOT" merge-base --is-ancestor "$sha" origin/main 2>/dev/null \
        || wrangle_die "target $sha is not on origin/main"
}

# The Release Gate catches un-finalized pins too, but 10 minutes later and as an
# opaque "gate failed". Say it up front, with the remedy.
wrangle_check_pins_finalized() {
    "$SCRIPT_DIR/check_pin_main_history.sh" >/dev/null 2>&1 && return 0
    printf 'cut_release: the self-ref pins are not on main'"'"'s first-parent history.\n' >&2
    printf '\n  An in-PR converge pins branch commits; only a post-merge bump can reach\n' >&2
    printf '  first-parent history. Run the finalize, open it as a PR, merge it as a\n' >&2
    printf '  MERGE COMMIT (not a squash), then cut at that commit:\n\n' >&2
    printf '    tools/finalize_pins.sh\n\n' >&2
    return 1
}

# Dispatch the Release Gate on the target and poll it. A locally-run preflight
# cannot substitute: the pin gates read origin/main's history, so a stale or
# shallow checkout can produce a confident false green.
wrangle_release_gate_green() {
    local sha="$1"
    printf 'cut_release: dispatching %s on %s\n' "$GATE_WORKFLOW" "${sha:0:8}"
    gh workflow run "$GATE_WORKFLOW" --ref "$sha" >/dev/null \
        || wrangle_die "could not dispatch $GATE_WORKFLOW"

    local id="" i
    for ((i = 0; i < 30; i++)); do
        sleep 5
        id="$(gh run list --workflow "$GATE_WORKFLOW" --commit "$sha" \
            --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
        [[ -n "$id" ]] && break
    done
    [[ -n "$id" ]] || wrangle_die "the dispatched $GATE_WORKFLOW run never appeared"

    printf 'cut_release: waiting on run %s\n' "$id"
    for ((i = 0; i < 240; i++)); do
        local status
        status="$(gh run view "$id" --json status -q .status 2>/dev/null || true)"
        [[ "$status" == "completed" ]] && break
        sleep 15
    done

    local conclusion
    conclusion="$(gh run view "$id" --json conclusion -q .conclusion 2>/dev/null || true)"
    if [[ "$conclusion" != "success" ]]; then
        wrangle_die "Release Gate is ${conclusion:-not finished} on ${sha:0:8} — refusing to tag"
    fi
    printf 'cut_release: Release Gate green on %s\n' "${sha:0:8}"
}

# The tag is the owner's call and it cannot be undone.
wrangle_confirm() {
    local v="$1" sha="$2"
    if [[ ! -t 0 ]]; then
        wrangle_die "refusing to cut non-interactively — the tag is immutable and is the owner's call"
    fi
    printf '\nAbout to cut %s at %s (immutable, no undo).\nType the version to confirm: ' "$v" "${sha:0:8}"
    local reply
    read -r reply
    [[ "$reply" == "$v" ]] || wrangle_die "confirmation did not match — nothing tagged"
}

wrangle_cut_release() {
    local version="$1" notes="$2" target="${3:-}"

    wrangle_check_version "$version"
    wrangle_check_notes "$notes"
    wrangle_check_tag_free "$version"

    if [[ -z "$target" ]]; then
        git -C "$REPO_ROOT" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main
        target="$(git -C "$REPO_ROOT" rev-parse origin/main)"
    fi
    wrangle_check_target_on_main "$target"
    wrangle_check_pins_finalized "$target"
    wrangle_release_gate_green "$target"
    wrangle_confirm "$version" "$target"

    gh release create "$version" \
        --target "$target" \
        --title "$version" \
        --notes-file "$notes" \
        --latest \
        || wrangle_die "gh release create failed"

    printf 'cut_release: released %s at %s\n' "$version" "${target:0:8}"
}

main() {
    local version="" notes="" target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) target="${2:-}"; shift 2 ;;
            -*) printf 'cut_release: unknown flag: %s\n' "$1" >&2; exit 2 ;;
            *)
                if [[ -z "$version" ]]; then version="$1"
                elif [[ -z "$notes" ]]; then notes="$1"
                else printf 'cut_release: unexpected argument: %s\n' "$1" >&2; exit 2
                fi
                shift
                ;;
        esac
    done
    if [[ -z "$version" || -z "$notes" ]]; then
        printf 'Usage: cut_release.sh <version> <notes-file> [--target <sha>]\n' >&2
        exit 2
    fi
    wrangle_cut_release "$version" "$notes" "$target"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
