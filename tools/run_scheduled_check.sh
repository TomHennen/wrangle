#!/bin/bash
set -euo pipefail
set -f

# tools/run_scheduled_check.sh — run an unattended check and keep its
# wrangle-alert issue in sync: clear on exit 0, warn-and-pass on exit 2 (a
# backend blip, not something a human should be paged for every run), raise
# on ANY other exit — not just the documented 1, so a crash (missing binary,
# an unguarded command dying under set -e, killed by the runner) still files
# an alert instead of just leaving a red run nobody watches (#839). Lets a
# scheduled workflow's step stay one line.
#
# Usage: run_scheduled_check.sh <alert-key> <title> <check-script> [args...]
#
# Exit: mirrors <check-script>, except exit 2 is remapped to 0 (warn, don't
# fail the workflow run on an inconclusive backend).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# wrangle_run_scheduled_check <key> <title> <check-script> [args...] — see
# header. Returns the remapped exit code described there.
wrangle_run_scheduled_check() {
    local key="$1" title="$2" out rc=0
    shift 2

    out="$(mktemp)"
    "$@" > "$out" 2>&1 || rc=$?
    cat "$out"

    case "$rc" in
        0) "$SCRIPT_DIR/wrangle_alert.sh" clear "$key" || true ;;
        2)
            printf '::warning::%s: undetermined this run (backend unreachable)\n' "$title"
            rc=0
            ;;
        *)
            printf '\ncheck exited %s\n' "$rc" >> "$out"
            # Unlike clear, a failed raise must not go silent: it's the one
            # thing standing between a red run and nobody noticing.
            "$SCRIPT_DIR/wrangle_alert.sh" raise "$key" "$title" "$out" \
                || printf '::error::%s: FAILED to file the wrangle-alert issue\n' "$title"
            ;;
    esac

    rm -f "$out"
    return "$rc"
}

main() {
    if [[ "$#" -lt 3 ]]; then
        printf 'Usage: %s <alert-key> <title> <check-script> [args...]\n' "${0##*/}" >&2
        exit 2
    fi
    wrangle_run_scheduled_check "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
