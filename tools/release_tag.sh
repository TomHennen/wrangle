#!/bin/bash
set -euo pipefail
set -f

# release_tag.sh — verify a wrangle release target and publish the Release.
#
# Usage: release_tag.sh <version> <target-sha> [--preview]
#
# Runs inside .github/workflows/release.yml: once before the environment gate
# with --preview (verify, then render what approval would publish), and once
# after the owner has approved, to publish. Every precondition is re-checked in
# both passes rather than trusted from the dispatcher or from the preview,
# because the tag is immutable and there is no undo:
#
#   1. the workflow run is on main (this is the reviewed code path)
#   2. version is vX.Y.Z and target is a 40-hex sha
#   3. the tag does not exist, locally or on the remote
#   4. the target is an ancestor of origin/main
#   5. the Release Gate has a completed, successful run whose head sha IS the target
#   6. docs/release-notes/<version>.md exists at the target and is non-empty
#
# Environment:
#   RELEASE_DRY_RUN        the Release is created ONLY when this is exactly
#                          "false"; every other value verifies and stops
#   GH_TOKEN               token with contents:write and actions:read
#   GITHUB_REPOSITORY      owner/repo (defaults to TomHennen/wrangle)
#   GITHUB_REF             refused unless refs/heads/main when set
#   GITHUB_STEP_SUMMARY    where --preview renders (stdout when unset)
#   WRANGLE_REPO_ROOT      checkout to read history from (defaults to this repo)
#   WRANGLE_RELEASE_GATE   gate workflow file name (defaults to release_gate.yml)
#
# Exit: 0 released (or verified without releasing), 1 a check failed (nothing
# tagged), 2 usage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${WRANGLE_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
GATE_WORKFLOW="${WRANGLE_RELEASE_GATE:-release_gate.yml}"
RELEASE_REPO="${GITHUB_REPOSITORY:-TomHennen/wrangle}"
NOTES_DIR="docs/release-notes"

wrangle_die() { printf 'release_tag: %s\n' "$1" >&2; return 1; }

# A run off another branch would tag with code that never passed review.
wrangle_check_workflow_ref() {
    local ref="${GITHUB_REF:-}"
    [[ -z "$ref" || "$ref" == "refs/heads/main" ]] \
        || wrangle_die "refusing to tag from $ref — the release workflow runs on main"
}

wrangle_check_version() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || wrangle_die "version must be vX.Y.Z (goreleaser needs semver), got: $1"
}

wrangle_check_target_format() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]] \
        || wrangle_die "target must be a 40-character hex sha, got: $1"
}

wrangle_check_tag_free() {
    local v="$1" refs
    if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$v" >/dev/null 2>&1; then
        wrangle_die "tag $v already exists locally — tags are immutable, refusing"
    fi
    refs="$(gh api "repos/$RELEASE_REPO/git/matching-refs/tags/$v")" \
        || wrangle_die "could not list tags on $RELEASE_REPO"
    printf '%s' "$refs" | jq -e --arg v "$v" 'all(.[]; .ref != "refs/tags/\($v)")' >/dev/null \
        || wrangle_die "tag $v already exists on $RELEASE_REPO — tags are immutable, refusing"
}

wrangle_check_target_on_main() {
    local sha="$1"
    git -C "$REPO_ROOT" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main \
        || wrangle_die "could not fetch origin/main"
    git -C "$REPO_ROOT" merge-base --is-ancestor "$sha" origin/main 2>/dev/null \
        || wrangle_die "target $sha is not on origin/main"
}

# The gate proves the curated tool-image digests are release-worthy. It must have
# finished successfully on the exact commit being tagged, not merely on main.
WRANGLE_GATE_RUN_URL=""
wrangle_check_gate_green() {
    local sha="$1" runs
    runs="$(gh run list --workflow "$GATE_WORKFLOW" --commit "$sha" --limit 20 \
        --json headSha,status,conclusion,url)" \
        || wrangle_die "could not list $GATE_WORKFLOW runs"
    WRANGLE_GATE_RUN_URL="$(printf '%s' "$runs" | jq -r --arg sha "$sha" \
        '[.[] | select(.headSha == $sha and .status == "completed" and .conclusion == "success")][0].url // ""')" \
        || wrangle_die "could not read $GATE_WORKFLOW runs"
    [[ -n "$WRANGLE_GATE_RUN_URL" ]] \
        || wrangle_die "no completed, successful $GATE_WORKFLOW run on ${sha:0:8} — refusing to tag"
}

# Notes are read from the target commit, not the working tree: the workflow
# cannot see the operator's disk, and the tagged content is what ships.
wrangle_notes_at_target() {
    local sha="$1" v="$2" out="$3"
    git -C "$REPO_ROOT" show "$sha:$NOTES_DIR/$v.md" > "$out" 2>/dev/null \
        || wrangle_die "no release notes at $NOTES_DIR/$v.md in ${sha:0:8}"
    [[ -s "$out" && -n "$(tr -d '[:space:]' < "$out")" ]] \
        || wrangle_die "release notes $NOTES_DIR/$v.md are empty"
}

# What approving this deployment would publish, on the run page the approver is
# already looking at — a wrong-but-valid target passes every check above.
wrangle_write_preview() {
    local version="$1" sha="$2" notes="$3"
    {
        printf '## Approval publishes %s\n\n' "$version"
        printf -- '- Commit: %s (%s)\n' "$sha" \
            "$(git -C "$REPO_ROOT" log -1 --format=%s "$sha")"
        printf -- '- Release Gate: %s\n' "$WRANGLE_GATE_RUN_URL"
        printf -- '- The tag and the Release are immutable once published.\n\n'
        printf '### Release notes (%s)\n\n' "$NOTES_DIR/$version.md"
        cat "$notes"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
}

WRANGLE_NOTES_TMP=""
wrangle_cleanup() {
    if [[ -n "$WRANGLE_NOTES_TMP" ]]; then rm -f "$WRANGLE_NOTES_TMP"; fi
}

wrangle_release_tag() {
    local version="$1" target="$2" preview="$3" notes

    wrangle_check_workflow_ref
    wrangle_check_version "$version"
    wrangle_check_target_format "$target"
    wrangle_check_tag_free "$version"
    wrangle_check_target_on_main "$target"
    wrangle_check_gate_green "$target"

    notes="$(mktemp)"
    WRANGLE_NOTES_TMP="$notes"
    wrangle_notes_at_target "$target" "$version" "$notes"

    if [[ "$preview" == "true" ]]; then
        wrangle_write_preview "$version" "$target" "$notes"
        printf 'release_tag: verified %s at %s, awaiting approval\n' "$version" "${target:0:8}"
        return 0
    fi

    # Publishing takes the one literal that means "not a dry run"; anything else
    # — unset, empty, a typo — stops here, because the tag cannot be undone.
    if [[ "${RELEASE_DRY_RUN:-}" != "false" ]]; then
        printf 'release_tag: dry run (RELEASE_DRY_RUN=%s) — every check passed for %s at %s, nothing tagged\n' \
            "${RELEASE_DRY_RUN:-<unset>}" "$version" "${target:0:8}"
        return 0
    fi

    gh release create "$version" \
        --target "$target" \
        --title "$version" \
        --notes-file "$notes" \
        --latest \
        || wrangle_die "gh release create failed"

    printf 'release_tag: released %s at %s\n' "$version" "${target:0:8}"
}

main() {
    local version="" target="" preview="false"
    trap wrangle_cleanup EXIT
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --preview) preview="true"; shift ;;
            -*) printf 'release_tag: unknown flag: %s\n' "$1" >&2; exit 2 ;;
            *)
                if [[ -z "$version" ]]; then version="$1"
                elif [[ -z "$target" ]]; then target="$1"
                else printf 'release_tag: unexpected argument: %s\n' "$1" >&2; exit 2
                fi
                shift
                ;;
        esac
    done
    if [[ -z "$version" || -z "$target" ]]; then
        printf 'Usage: release_tag.sh <version> <target-sha> [--preview]\n' >&2
        exit 2
    fi
    wrangle_release_tag "$version" "$target" "$preview"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
