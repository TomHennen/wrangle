#!/bin/bash
set -euo pipefail
set -f

# Resolve the dist files whose metadata the attest job signs into GITHUB_OUTPUT's
# `subjects` key (lib/resolve_subjects.sh). These are the SAME subjects the
# verify job binds its VSA to, so attest-signed metadata and the VSA bind
# identical sha256 digests (issue #550 M4).
#
# Exactly one of:
#   SUBJECT_CHECKSUMS  a sha256sum-format file (go: dist/checksums.txt); each
#                      '<sha256>  <filename>' line names a DIST_DIR/<filename>.
#   SUBJECT_PATH       a glob of dist files (npm/python: dist/*).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/resolve_subjects.sh
source "$SCRIPT_DIR/../../lib/resolve_subjects.sh"

if [[ -n "${SUBJECT_CHECKSUMS:-}" && -n "${SUBJECT_PATH:-}" ]] \
    || [[ -z "${SUBJECT_CHECKSUMS:-}" && -z "${SUBJECT_PATH:-}" ]]; then
    printf 'resolve_subjects: pass exactly one of SUBJECT_CHECKSUMS or SUBJECT_PATH\n' >&2
    exit 1
fi

declare -a WRANGLE_RESOLVED=()
if [[ -n "${SUBJECT_CHECKSUMS:-}" ]]; then
    wrangle_resolve_checksums "$SUBJECT_CHECKSUMS"
else
    wrangle_resolve_glob "$SUBJECT_PATH"
fi

wrangle_emit_subjects
