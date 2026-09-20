#!/bin/bash
set -euo pipefail
set -f

# tools/wrangle_alert.sh — file or clear a `wrangle-alert`-labeled issue for an
# unattended check gone red (CLAUDE.md: agents check this label at session
# start), keyed so a scheduled workflow's repeated runs never duplicate the
# issue or double-close it.
#
# <key> is embedded as a hidden HTML-comment marker in the issue body, which
# raise/clear search for instead of relying on title text or a database.
#
# Usage:
#   wrangle_alert.sh raise <key> <title> <body-file>   # open, or comment if already open
#   wrangle_alert.sh clear <key>                        # close the open one, if any
#
# Exit: 0 done (including "already open" / "nothing to clear" no-ops),
#       1 bad usage or invalid key, 2 gh/jq failed.

WRANGLE_ALERT_REPO="${WRANGLE_ALERT_REPO:-TomHennen/wrangle}"
WRANGLE_ALERT_LABEL="${WRANGLE_ALERT_LABEL:-wrangle-alert}"
KEY_RE='^[a-z][a-z0-9-]*$'

wrangle_alert_marker() {
    printf '<!-- wrangle-alert:%s -->' "$1"
}

# wrangle_alert_find_open <key> — print the open issue number carrying <key>'s
# marker (empty if none). Returns 2 on a gh/jq failure.
wrangle_alert_find_open() {
    local key="$1" marker list
    marker="$(wrangle_alert_marker "$key")"
    list="$(gh issue list --repo "$WRANGLE_ALERT_REPO" --label "$WRANGLE_ALERT_LABEL" \
        --state open --json number,body --limit 100)" || return 2
    jq -r --arg m "$marker" 'map(select((.body // "") | contains($m))) | .[0].number // empty' <<<"$list"
}

# wrangle_alert_last_update <number> <key> — print the most recent content
# already on the issue: the last comment if any, else the issue body with the
# marker line stripped. Returns 2 on a gh/jq failure.
wrangle_alert_last_update() {
    local number="$1" key="$2" last
    last="$(gh issue view "$number" --repo "$WRANGLE_ALERT_REPO" --json comments \
        --jq '.comments[-1].body // empty')" || return 2
    if [[ -z "$last" ]]; then
        last="$(gh issue view "$number" --repo "$WRANGLE_ALERT_REPO" --json body \
            --jq '.body // empty')" || return 2
        last="$(printf '%s\n' "$last" | grep -vF "$(wrangle_alert_marker "$key")")"
    fi
    printf '%s' "$last"
}

wrangle_alert_raise() {
    local key="$1" title="$2" body_file="$3" number body_with_marker last

    [[ "$key" =~ $KEY_RE ]] || { printf 'wrangle_alert: invalid key: %s\n' "$key" >&2; return 1; }
    [[ -f "$body_file" ]] || { printf 'wrangle_alert: body file not found: %s\n' "$body_file" >&2; return 1; }

    number="$(wrangle_alert_find_open "$key")" \
        || { printf 'wrangle_alert: could not list open %s issues\n' "$WRANGLE_ALERT_LABEL" >&2; return 2; }

    if [[ -n "$number" ]]; then
        # Dedup: a standing red re-raising an unchanged failure (same output,
        # same URL) updates nothing rather than piling up identical comments —
        # simpler than a time-based cooldown, and precise instead of guessing
        # at a schedule.
        last="$(wrangle_alert_last_update "$number" "$key")" \
            || { printf 'wrangle_alert: could not read #%s to check for a duplicate\n' "$number" >&2; return 2; }
        if [[ "$last" == "$(cat "$body_file")" ]]; then
            printf 'wrangle_alert: #%s for %s unchanged since the last update; not commenting\n' "$number" "$key"
            return 0
        fi
        gh issue comment "$number" --repo "$WRANGLE_ALERT_REPO" --body-file "$body_file" \
            || { printf 'wrangle_alert: could not comment on #%s\n' "$number" >&2; return 2; }
        printf 'wrangle_alert: commented on existing #%s for %s\n' "$number" "$key"
        return 0
    fi

    body_with_marker="$(mktemp)"
    cat "$body_file" > "$body_with_marker"
    printf '\n\n%s\n' "$(wrangle_alert_marker "$key")" >> "$body_with_marker"
    if ! gh issue create --repo "$WRANGLE_ALERT_REPO" --title "$title" \
        --label "$WRANGLE_ALERT_LABEL" --body-file "$body_with_marker" >/dev/null; then
        rm -f "$body_with_marker"
        printf 'wrangle_alert: could not open an issue for %s\n' "$key" >&2
        return 2
    fi
    rm -f "$body_with_marker"
    printf 'wrangle_alert: opened a new %s issue for %s\n' "$WRANGLE_ALERT_LABEL" "$key"
}

wrangle_alert_clear() {
    local key="$1" number

    [[ "$key" =~ $KEY_RE ]] || { printf 'wrangle_alert: invalid key: %s\n' "$key" >&2; return 1; }

    number="$(wrangle_alert_find_open "$key")" \
        || { printf 'wrangle_alert: could not list open %s issues\n' "$WRANGLE_ALERT_LABEL" >&2; return 2; }

    if [[ -z "$number" ]]; then
        printf 'wrangle_alert: no open %s issue for %s\n' "$WRANGLE_ALERT_LABEL" "$key"
        return 0
    fi

    gh issue close "$number" --repo "$WRANGLE_ALERT_REPO" --comment 'green again — closing' \
        || { printf 'wrangle_alert: could not close #%s\n' "$number" >&2; return 2; }
    printf 'wrangle_alert: closed #%s for %s\n' "$number" "$key"
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        raise)
            [[ "$#" -eq 4 ]] || { printf 'Usage: %s raise <key> <title> <body-file>\n' "${0##*/}" >&2; exit 1; }
            wrangle_alert_raise "$2" "$3" "$4"
            ;;
        clear)
            [[ "$#" -eq 2 ]] || { printf 'Usage: %s clear <key>\n' "${0##*/}" >&2; exit 1; }
            wrangle_alert_clear "$2"
            ;;
        *)
            printf 'Usage: %s raise <key> <title> <body-file> | clear <key>\n' "${0##*/}" >&2
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
