#!/bin/bash
# Resolve the verify action's subjects: pass through SUBJECTS_IN if set, else
# expand the DIST_FILES JSON array to one dist/<file> subject per line. Writes a
# heredoc to GITHUB_OUTPUT's `subjects` key.
set -euo pipefail
set -f

if [[ -n "${SUBJECTS_IN:-}" ]]; then
    subjects="$SUBJECTS_IN"
else
    # Run jq before the group write: a `{ …; } >> file` group returns the last
    # command's status, so a jq failure inside it would be masked.
    subjects="$(printf '%s' "$DIST_FILES" | jq -r '.[] | "dist/" + .')"
fi
{
    printf 'subjects<<WRANGLE_EOF\n'
    printf '%s\n' "$subjects"
    printf 'WRANGLE_EOF\n'
} >> "$GITHUB_OUTPUT"
