#!/bin/bash
set -euo pipefail
set -f

# companion_tag.sh — put a tag on the wrangle-test companion so its showcase
# workflows fire. Sourced by the scripts that trigger a companion run.
#
# companion_tag_exists <repo> <tag>
#   0 when refs/tags/<tag> is already on the companion.
#
# companion_create_tag_at_main <repo> <tag> [token]
#   Creates refs/tags/<tag> at the companion's main HEAD; an existing tag is a
#   no-op. <token> runs the create call alone under that credential, for callers
#   whose read token is not the one with contents:write.
#   Returns 0 created or already present, 1 main HEAD unresolvable or create failed.
#
# The creating credential must be a PAT: a tag created with GITHUB_TOKEN does not
# fire the companion's `on: push: tags` workflows.

companion_tag_exists() {
    gh api "repos/$1/git/ref/tags/$2" >/dev/null 2>&1
}

companion_create_tag_at_main() {
    local repo="$1" tag="$2" token="${3:-${GH_TOKEN:-}}" target
    if companion_tag_exists "$repo" "$tag"; then
        printf 'Tag %s already exists on %s; nothing to create\n' "$tag" "$repo"
        return 0
    fi
    if ! target="$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)"; then
        printf 'ERROR: could not resolve %s main HEAD\n' "$repo" >&2
        return 1
    fi
    if [[ -z "$target" ]]; then
        printf 'ERROR: empty SHA returned for %s main HEAD\n' "$repo" >&2
        return 1
    fi
    printf 'Creating tag %s -> %s on %s\n' "$tag" "$target" "$repo"
    # The created-ref JSON would otherwise land in the log.
    if ! GH_TOKEN="$token" gh api "repos/$repo/git/refs" \
        --method POST \
        --field "ref=refs/tags/$tag" \
        --field "sha=$target" >/dev/null; then
        printf 'ERROR: could not create tag %s on %s\n' "$tag" "$repo" >&2
        return 1
    fi
}
