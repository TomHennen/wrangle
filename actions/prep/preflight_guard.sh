#!/usr/bin/env bash
# preflight_guard.sh — refuse trigger patterns known to expose wrangle's
# reusable workflows to supply-chain attack classes. Fails the workflow
# fast; downstream jobs with `needs: [guard]` skip via standard
# `needs:` propagation.
#
# Required env (set by prep's step that runs it):
#   EVENT_NAME   — github.event_name
#   OUTER_EVENT  — github.event.workflow_run.event (empty unless event is
#                  workflow_run)
#
# Refusals are listed below. New refusal categories belong here, with a
# matching entry in docs/SPEC.md#trigger-model.

set -euo pipefail
set -f    # env vars come from GitHub event context — disable globbing defensively

fail() {
    printf '::error::wrangle refuses %s.\n' "$1" >&2
    printf "::error::This trigger pattern combined with a checkout of PR head SHA is the 'pwn request' vector that compromised TanStack/router via Mini Shai-Hulud in May 2026.\n" >&2
    printf '::error::Move build/publish to a push-triggered workflow (push to main or tags). See docs/SPEC.md#trigger-model.\n' >&2
    exit 1
}

if [[ "$EVENT_NAME" == "pull_request_target" ]]; then
    fail "pull_request_target invocations"
fi

if [[ "$EVENT_NAME" == "workflow_run" && "$OUTER_EVENT" == "pull_request_target" ]]; then
    fail "workflow_run invocations triggered by pull_request_target"
fi

printf 'Event "%s" allowed.\n' "$EVENT_NAME"
