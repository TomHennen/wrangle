#!/bin/bash
set -euo pipefail
set -f

# cut_release.sh — dispatch wrangle's release workflow (cut-release runbook, Phase 4).
#
# Usage: cut_release.sh <version> [--target <sha>] [--dry-run]
#          e.g. cut_release.sh v0.4.2
#
# This script never tags. It checks what can be checked cheaply, then dispatches
# .github/workflows/release.yml, whose tag job waits for the owner to approve the
# `release` environment deployment and re-verifies everything before
# `gh release create` — the tag is immutable and there is no undo:
#
#   1. version is vX.Y.Z (goreleaser needs a semver-parseable tag)
#   2. the tag does not already exist, locally or on the remote
#   3. the target commit is origin/main's HEAD — workflow_dispatch only accepts a
#      branch or tag ref, so the Release Gate can only be dispatched on main, and
#      a target that is not main's HEAD would have the gate verify another commit
#   4. docs/release-notes/<version>.md exists at the target and is non-empty
#      (never --generate-notes: the runbook wants benefit-first prose)
#   5. the companion's curated showcase already pins wrangle at <version>, so the
#      post-release run exercises this release rather than the previous one
#   6. the Release Gate is green ON THAT COMMIT — dispatched here and polled,
#      because the gate is the only thing that proves the curated tool-image
#      digests are release-worthy, and a local run cannot prove it (a stale or
#      shallow checkout yields a confident false green)
#
# Exit: 0 dispatched, 1 a precheck failed (nothing dispatched), 2 usage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${WRANGLE_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
GATE_WORKFLOW="${WRANGLE_RELEASE_GATE:-release_gate.yml}"
RELEASE_WORKFLOW="${WRANGLE_RELEASE_WORKFLOW:-release.yml}"
SHOWCASE_SCRIPT="${WRANGLE_SHOWCASE_SCRIPT:-$SCRIPT_DIR/../test/integration/run_release_showcase.sh}"
NOTES_DIR="docs/release-notes"

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

# Read from the target commit, not the working tree: the workflow reads the same
# blob out of its own checkout, and the tagged content is what ships.
wrangle_check_notes() {
    local sha="$1" v="$2" body
    body="$(git -C "$REPO_ROOT" show "$sha:$NOTES_DIR/$v.md" 2>/dev/null)" \
        || wrangle_die "no release notes at $NOTES_DIR/$v.md in ${sha:0:8}"
    [[ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ]] \
        || wrangle_die "release notes $NOTES_DIR/$v.md are empty"
}

wrangle_check_target_on_main() {
    local sha="$1"
    git -C "$REPO_ROOT" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main
    git -C "$REPO_ROOT" merge-base --is-ancestor "$sha" origin/main 2>/dev/null \
        || wrangle_die "target $sha is not on origin/main"
}

wrangle_check_showcase_pin() {
    "$SHOWCASE_SCRIPT" --check-pin "$1" \
        || wrangle_die "the companion showcase does not pin wrangle at $1 — land that bump first"
}

# Dispatch the Release Gate on the target and poll it. A locally-run preflight
# cannot substitute: provenance freshness diffs against full history, so a stale
# or shallow checkout can produce a confident false green.
#
# workflow_dispatch only accepts a branch or tag ref, never a raw sha, so this
# dispatches origin/main and refuses unless the target IS origin/main's HEAD —
# otherwise the gate would verify a different commit than the one being tagged.
wrangle_release_gate_green() {
    local sha="$1"
    local head
    head="$(git -C "$REPO_ROOT" rev-parse origin/main)"
    [[ "$head" == "$sha" ]] || wrangle_die \
        "target ${sha:0:8} is not origin/main's HEAD (${head:0:8}) — the gate can only be dispatched on a branch"

    printf 'cut_release: dispatching %s on main (%s)\n' "$GATE_WORKFLOW" "${sha:0:8}"
    gh workflow run "$GATE_WORKFLOW" --ref main >/dev/null \
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
        wrangle_die "Release Gate is ${conclusion:-not finished} on ${sha:0:8} — refusing to dispatch the release"
    fi
    printf 'cut_release: Release Gate green on %s\n' "${sha:0:8}"
}

# The tag itself is the owner's call, made by approving the `release` deployment.
wrangle_dispatch_release() {
    local version="$1" sha="$2" dry_run="$3"
    local before url="" id="" i

    before="$(gh run list --workflow "$RELEASE_WORKFLOW" --limit 1 \
        --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"

    local -a args=(--ref main -f "version=$version" -f "target=$sha")
    if [[ "$dry_run" == "true" ]]; then args+=(-f dry-run=true); fi
    gh workflow run "$RELEASE_WORKFLOW" "${args[@]}" >/dev/null \
        || wrangle_die "could not dispatch $RELEASE_WORKFLOW"

    for ((i = 0; i < 24; i++)); do
        sleep 5
        id="$(gh run list --workflow "$RELEASE_WORKFLOW" --limit 1 \
            --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
        if [[ -n "$id" && "$id" != "$before" ]]; then
            url="$(gh run view "$id" --json url -q .url 2>/dev/null || true)"
            break
        fi
    done

    printf 'cut_release: dispatched %s for %s at %s\n' "$RELEASE_WORKFLOW" "$version" "${sha:0:8}"
    if [[ -n "$url" ]]; then
        printf 'cut_release: %s\n' "$url"
    else
        printf 'cut_release: the run is on the Actions tab (%s)\n' "$RELEASE_WORKFLOW"
    fi
    printf 'An approval is waiting: the owner must approve the release deployment on that run. Nothing is tagged until they do.\n'
}

wrangle_cut_release() {
    local version="$1" target="${2:-}" dry_run="${3:-false}"

    wrangle_check_version "$version"
    wrangle_check_tag_free "$version"

    # The workflow takes a 40-hex sha and nothing else, so resolve here.
    if [[ -z "$target" ]]; then
        git -C "$REPO_ROOT" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main
        target="$(git -C "$REPO_ROOT" rev-parse origin/main)"
    else
        target="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$target^{commit}")" \
            || wrangle_die "unknown target commit: $target"
    fi
    wrangle_check_target_on_main "$target"
    wrangle_check_notes "$target" "$version"
    wrangle_check_showcase_pin "$version"
    wrangle_release_gate_green "$target"
    wrangle_dispatch_release "$version" "$target" "$dry_run"
}

main() {
    local version="" target="" dry_run="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) target="${2:-}"; shift 2 ;;
            --dry-run) dry_run="true"; shift ;;
            -*) printf 'cut_release: unknown flag: %s\n' "$1" >&2; exit 2 ;;
            *)
                if [[ -z "$version" ]]; then version="$1"
                else printf 'cut_release: unexpected argument: %s\n' "$1" >&2; exit 2
                fi
                shift
                ;;
        esac
    done
    if [[ -z "$version" ]]; then
        printf 'Usage: cut_release.sh <version> [--target <sha>] [--dry-run]\n' >&2
        exit 2
    fi
    wrangle_cut_release "$version" "$target" "$dry_run"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
