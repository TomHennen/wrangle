#!/usr/bin/env bash
# release_gate.sh — decide whether release-time side effects (provenance,
# publish, etc.) should run for the current event.
#
# Required env (set by the composite action wrapper):
#   EVENTS_INPUT  — caller's release-events value
#   EVENT_NAME    — github.event_name
#   REF           — github.ref
#   GITHUB_OUTPUT — set by GitHub Actions for action outputs
#
# Writes `should-release=true|false` to $GITHUB_OUTPUT.
# Exits 0 on a successful decision, 2 on invalid input.

set -euo pipefail
# Disable globbing — events input is external and case-pattern matching
# in this script must not perform pathname expansion.
set -f

# Use ${var?} (no colon) for EVENTS_INPUT so an empty string falls through
# to the case statement and exits 2 with an "events input is empty" message
# rather than the generic shell parameter-expansion error.
: "${EVENTS_INPUT?EVENTS_INPUT not set}"
: "${EVENT_NAME:?EVENT_NAME not set}"
: "${REF:?REF not set}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT not set}"

# Reject CR/LF (caller workflows are authored as YAML and CR sneaks into
# windows-edited files; treat it as invalid input rather than silently
# mismatching tokens).
case "$EVENTS_INPUT" in
  *$'\r'*|*$'\n'*)
    printf 'release_gate: events input contains CR/LF; reject\n' >&2
    exit 2
    ;;
esac

# Strip leading/trailing whitespace so " tag-only " still matches the
# literal-shorthand cases below. Without this, a YAML formatting accident
# (e.g., a stray space after the colon) bypasses the shorthand match,
# falls through to the comma-list path, and fails the event_name regex
# with a confusing "invalid token" error — even though the token IS a
# known shorthand.
EVENTS_INPUT="${EVENTS_INPUT#"${EVENTS_INPUT%%[![:space:]]*}"}"
EVENTS_INPUT="${EVENTS_INPUT%"${EVENTS_INPUT##*[![:space:]]}"}"

# Allowed event-name regex: lowercase letter, lowercase letters / digits /
# underscore. Covers every documented github.event_name (push,
# pull_request, workflow_dispatch, schedule, merge_group, release,
# repository_dispatch, etc.). Reject anything else — typos shouldn't
# silently match nothing.
event_name_re='^[a-z][a-z0-9_]*$'

decide() {
  case "$EVENTS_INPUT" in
    non-pull-request)
      [[ "$EVENT_NAME" != pull_* ]]
      ;;
    tag-only)
      [[ "$EVENT_NAME" == "push" && "$REF" == refs/tags/* ]]
      ;;
    main-and-tags)
      [[ "$EVENT_NAME" == "push" && ( "$REF" == "refs/heads/main" || "$REF" == refs/tags/* ) ]]
      ;;
    "")
      printf 'release_gate: events input is empty\n' >&2
      exit 2
      ;;
    *)
      # Treat as comma-separated event_name list. Validate each token,
      # then match github.event_name against the set.
      local tokens
      read -ra tokens <<< "${EVENTS_INPUT//,/ }"
      if (( ${#tokens[@]} == 0 )); then
        printf 'release_gate: events input %q resolved to no tokens\n' "$EVENTS_INPUT" >&2
        exit 2
      fi
      local matched=false
      for tok in "${tokens[@]}"; do
        if [[ ! "$tok" =~ $event_name_re ]]; then
          printf 'release_gate: invalid token %q in events input (expected lowercase event name or known shorthand)\n' "$tok" >&2
          exit 2
        fi
        if [[ "$tok" == "$EVENT_NAME" ]]; then
          matched=true
        fi
      done
      $matched
      ;;
  esac
}

if decide; then
  result=true
else
  result=false
fi

printf 'should-release=%s\n' "$result" >> "$GITHUB_OUTPUT"
printf 'release_gate: events=%q event_name=%q ref=%q -> should-release=%s\n' \
  "$EVENTS_INPUT" "$EVENT_NAME" "$REF" "$result"
