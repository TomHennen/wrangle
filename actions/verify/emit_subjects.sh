#!/bin/bash
set -euo pipefail
set -f

# Resolve the verify action's subjects: pass through SUBJECTS_IN if set, else
# expand the DIST_FILES JSON array to one dist/<file> subject per line. Writes a
# heredoc to GITHUB_OUTPUT's `subjects` key (lib/resolve_subjects.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/resolve_subjects.sh
source "$SCRIPT_DIR/../../lib/resolve_subjects.sh"

if [[ -n "${SUBJECTS_IN:-}" ]]; then
    subjects="$SUBJECTS_IN"
else
    # Run jq in a command substitution so a malformed array fails closed under
    # set -e (a process-substitution loop would mask the jq exit status).
    subjects="$(printf '%s' "$DIST_FILES" | jq -r '.[] | "dist/" + .')"
fi

declare -a WRANGLE_RESOLVED=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    WRANGLE_RESOLVED+=("$line")
done <<< "$subjects"

wrangle_emit_subjects
