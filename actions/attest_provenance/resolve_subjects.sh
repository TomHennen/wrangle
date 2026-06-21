#!/bin/bash
# Resolve the dist files whose metadata the attest job signs, one path per line,
# into GITHUB_OUTPUT's `subjects` key. These are the SAME subjects the verify
# job self-digests its VSA against, so attest-signed metadata and the VSA bind
# identical sha256 digests (issue #550 M4).
#
# Exactly one of:
#   SUBJECT_CHECKSUMS  a sha256sum-format file (go: dist/checksums.txt); each
#                      '<sha256>  <filename>' line names a dist/<filename> subject.
#   SUBJECT_PATH       a glob of dist files (npm/python: dist/*).
#
# DIST_DIR (default dist) is the directory checksums-file basenames resolve under.

set -euo pipefail
set -f  # disable globbing — we expand SUBJECT_PATH explicitly, once

dist_dir="${DIST_DIR:-dist}"

if [[ -n "${SUBJECT_CHECKSUMS:-}" && -n "${SUBJECT_PATH:-}" ]] \
    || [[ -z "${SUBJECT_CHECKSUMS:-}" && -z "${SUBJECT_PATH:-}" ]]; then
    printf 'resolve_subjects: pass exactly one of SUBJECT_CHECKSUMS or SUBJECT_PATH\n' >&2
    exit 1
fi

subjects=()
if [[ -n "${SUBJECT_CHECKSUMS:-}" ]]; then
    if [[ ! -f "$SUBJECT_CHECKSUMS" ]]; then
        printf 'resolve_subjects: checksums file %s not found\n' "$SUBJECT_CHECKSUMS" >&2
        exit 1
    fi
    # Each line is '<sha256>  <filename>'; the subject is the dist file itself,
    # self-digested by wrangle-attest so attest and verify agree on the digest.
    while read -r _ file; do
        [[ -z "$file" ]] && continue
        subjects+=("$dist_dir/$file")
    done < "$SUBJECT_CHECKSUMS"
else
    # Expand the glob in one guarded window; nullglob would silently drop a
    # mistyped path, so a no-match is a hard error below.
    set +f
    for f in $SUBJECT_PATH; do
        [[ -f "$f" ]] && subjects+=("$f")
    done
    set -f
fi

if [[ "${#subjects[@]}" -eq 0 ]]; then
    printf 'resolve_subjects: no subject files resolved\n' >&2
    exit 1
fi

{
    printf 'subjects<<WRANGLE_EOF\n'
    printf '%s\n' "${subjects[@]}"
    printf 'WRANGLE_EOF\n'
} >> "$GITHUB_OUTPUT"
