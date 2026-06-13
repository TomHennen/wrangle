#!/usr/bin/env bats

# Divergence guard for third-party action pins inside wrangle's own workflows
# and composites. Dependabot updates each occurrence independently, and a
# composite whose directory it doesn't track is left on a stale SHA while the
# workflow copy moves on — which is how a fixed-CVE action lingers. This fails
# closed when the same action is pinned to more than one SHA across wrangle's
# internals.
#
# Scope is wrangle's *internal* refs: .github/workflows plus the composites
# under actions/, build/, tools/. gh_workflow_examples/ is excluded — those are
# adopter samples whose pins (e.g. their own publish-job setup-node) are
# intentionally independent of wrangle's internals. Self-references
# (TomHennen/wrangle/...) use a different pin scheme and are guarded elsewhere.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
}

@test "third-party action pins are uniform across wrangle's workflows and composites" {
    cd "$REPO_ROOT"

    # Unique action@sha pairs across the internal trees, minus self-refs.
    local pairs
    pairs="$(grep -rhoiE 'uses: [a-z0-9_.-]+/[a-z0-9_.-]+@[0-9a-f]{40}' \
        --include='*.yml' --include='*.yaml' \
        .github/workflows actions build tools \
        | sed -E 's/^[Uu]ses: //' \
        | grep -viE '^TomHennen/wrangle' \
        | sort -u)"

    [ -n "$pairs" ]  # guard against the regex silently matching nothing

    # An action whose name (the part before @) appears more than once in the
    # de-duplicated pair list is pinned to two different SHAs → drift.
    local dupes
    dupes="$(printf '%s\n' "$pairs" | awk -F@ '{print $1}' | sort | uniq -d)"

    if [ -n "$dupes" ]; then
        printf 'Third-party actions pinned to >1 SHA across wrangle internals:\n' >&2
        printf '%s\n' "$dupes" | while IFS= read -r action; do
            printf '%s\n' "$pairs" | grep -iF "$action@" >&2
        done
        return 1
    fi
}
