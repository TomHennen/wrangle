#!/bin/bash
set -euo pipefail
set -f  # values reach globs/case; disable pathname expansion

# bump_version_refs.sh — retarget every adopter-facing wrangle release ref at a
# new version tag (cut-release runbook, Phase 2).
#
# Usage: bump_version_refs.sh <new-version>      e.g. bump_version_refs.sh v0.4.0
#
# Two ref shapes are adopter-facing, and both must move together or a copy-paste
# hands adopters a stale wrangle with no signal (test/test_pin_consistency.bats
# is the fail-closed guard):
#
#   uses: <org>/wrangle/<path>@vX.Y.Z                          reusable workflows + actions
#   git+https://github.com/<org>/wrangle@vX.Y.Z#policies/...   ampel policy locators
#
# The current version is discovered from the refs themselves rather than passed
# in: they must already agree on exactly one version (the same invariant the
# oracle enforces), so a divergent tree fails closed here instead of being half
# rewritten.
#
# Deliberately NOT rewritten: docs/verifying_artifacts.md's worked example, which
# cites a real published wrangle-test curated release. Neither pattern matches it
# (it is a releases/download URL, not a uses: pin or a policy locator), and the
# new release's artifact does not exist until the tag is cut.
#
# Exit: 0 rewritten, 1 nothing to do or the tree disagrees on a version, 2 usage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${WRANGLE_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

USES_RE='uses: [A-Za-z0-9_.-]+/wrangle/[^@[:space:]]+@v[0-9]+\.[0-9]+\.[0-9]+'
POLICY_RE='github\.com/[A-Za-z0-9_.-]+/wrangle@v[0-9]+\.[0-9]+\.[0-9]+#policies'

# Every adopter-facing ref in the tree, as bare version tags.
wrangle_current_versions() {
    grep -rhoIE "$USES_RE|$POLICY_RE" \
        --include='*.yml' --include='*.yaml' --include='*.md' \
        --exclude-dir=.git --exclude-dir=.claude \
        "$REPO_ROOT" 2>/dev/null \
        | grep -oE '@v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^@//' | sort -u
}

wrangle_files_with_refs() {
    grep -rlIE "$USES_RE|$POLICY_RE" \
        --include='*.yml' --include='*.yaml' --include='*.md' \
        --exclude-dir=.git --exclude-dir=.claude \
        "$REPO_ROOT" 2>/dev/null | sort
}

# Rewrite both ref shapes in one file. Anchored on the wrangle path so a
# third-party action pinned at the same version is never touched.
wrangle_rewrite_file() {
    local file="$1" from="$2" to="$3"
    sed -i -E \
        -e "s|(uses: [A-Za-z0-9_.-]+/wrangle/[^@[:space:]]+)@${from}([[:space:]]\|\$)|\1@${to}\2|g" \
        -e "s|(github\.com/[A-Za-z0-9_.-]+/wrangle)@${from}(#policies)|\1@${to}\2|g" \
        "$file"
}

wrangle_bump_version_refs() {
    local new="$1"

    if [[ ! "$new" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'bump_version_refs: version must be vX.Y.Z, got: %s\n' "$new" >&2
        return 2
    fi

    local -a versions
    mapfile -t versions < <(wrangle_current_versions)

    if [[ "${#versions[@]}" -eq 0 ]]; then
        printf 'bump_version_refs: no adopter-facing wrangle refs found under %s\n' "$REPO_ROOT" >&2
        return 1
    fi
    if [[ "${#versions[@]}" -gt 1 ]]; then
        printf 'bump_version_refs: refs disagree on a version — fix the divergence first:\n' >&2
        printf '  %s\n' "${versions[@]}" >&2
        return 1
    fi

    local old="${versions[0]}"
    if [[ "$old" == "$new" ]]; then
        printf 'bump_version_refs: already at %s — nothing to do\n' "$new"
        return 1
    fi

    local -a files
    mapfile -t files < <(wrangle_files_with_refs)
    local f
    for f in "${files[@]}"; do
        wrangle_rewrite_file "$f" "$old" "$new"
    done

    # Fail closed if anything still names the old version: a partial rewrite is
    # exactly the drift the oracle exists to catch.
    local -a left
    mapfile -t left < <(wrangle_current_versions)
    if [[ "${#left[@]}" -ne 1 || "${left[0]}" != "$new" ]]; then
        printf 'bump_version_refs: rewrite incomplete, tree still names: %s\n' "${left[*]}" >&2
        return 1
    fi

    printf 'bump_version_refs: %s -> %s across %d file(s)\n' "$old" "$new" "${#files[@]}"
    printf '  %s\n' "${files[@]#"$REPO_ROOT"/}"
    printf '\nverifying_artifacts.md'\''s worked example still cites the published %s\n' "$old"
    printf 'curated release; update it with the Phase 4 recipe re-verification.\n'
}

main() {
    if [[ $# -ne 1 ]]; then
        printf 'Usage: bump_version_refs.sh <new-version>   e.g. v0.4.0\n' >&2
        exit 2
    fi
    wrangle_bump_version_refs "$1"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
