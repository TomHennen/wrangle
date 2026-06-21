#!/bin/bash
set -euo pipefail
set -f

# lib/resolve_subjects.sh — Shared subject-list resolution for the attest and
# verify jobs. Both derive the dist subjects a signature binds to from a build-
# type-specific input, then emit them as the `subjects` heredoc on GITHUB_OUTPUT.
# Sourced; the caller appends to WRANGLE_RESOLVED via the resolvers, then calls
# wrangle_emit_subjects.

# Expand each dist file named in a sha256sum-format checksums file ($1) into a
# DIST_DIR/<filename> subject, appending to the WRANGLE_RESOLVED array. Each line
# is '<sha256>  <filename>'; the subject is the dist file itself.
wrangle_resolve_checksums() {
    local checksums="$1" dist_dir="${DIST_DIR:-dist}" _ file
    if [[ ! -f "$checksums" ]]; then
        printf 'resolve_subjects: checksums file %s not found\n' "$checksums" >&2
        return 1
    fi
    while read -r _ file; do
        [[ -z "$file" ]] && continue
        WRANGLE_RESOLVED+=("$dist_dir/$file")
    done < "$checksums"
}

# Expand a glob ($1, e.g. dist/*) into each matching regular file, appending to
# WRANGLE_RESOLVED. nullglob would silently drop a mistyped path, so a no-match
# leaves WRANGLE_RESOLVED untouched and the caller fails closed. The glob runs in
# a subshell so `set +f` cannot leak glob-enabled state to the rest of the script.
wrangle_resolve_glob() {
    local matched f
    matched="$(
        set +f
        # shellcheck disable=SC2086 # intentional glob expansion of the pattern in $1
        printf '%s\n' $1
    )"
    while IFS= read -r f; do
        [[ -f "$f" ]] && WRANGLE_RESOLVED+=("$f")
    done <<< "$matched"
}

# Write WRANGLE_RESOLVED as the `subjects` heredoc on GITHUB_OUTPUT, one path per
# line. Fails closed on an empty set: a release subject is always present.
wrangle_emit_subjects() {
    if [[ "${#WRANGLE_RESOLVED[@]}" -eq 0 ]]; then
        printf 'resolve_subjects: no subject files resolved\n' >&2
        return 1
    fi
    {
        printf 'subjects<<WRANGLE_EOF\n'
        printf '%s\n' "${WRANGLE_RESOLVED[@]}"
        printf 'WRANGLE_EOF\n'
    } >> "$GITHUB_OUTPUT"
}
