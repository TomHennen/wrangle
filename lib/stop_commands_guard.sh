#!/bin/bash
# Runs a build/test invocation with GitHub Actions workflow-command
# processing suspended, neutralizing workflow-command injection via
# build-tool stdout.
#
# GitHub Actions interprets any line on a step's output stream that
# begins with `::` as a workflow command (`::add-path::`, `::add-mask::`,
# `::set-output::`, `::error::`, ...). A build tool — or a malicious
# dependency lifecycle hook (npm `postinstall`, a hostile test, a build
# backend, a Dockerfile `RUN`) — can therefore hijack the build job just
# by printing such a line. `::stop-commands::<token>` tells the runner to
# treat every subsequent line as plain text until it sees a matching
# `::<token>::` line; with a per-run unguessable token the build tool
# cannot re-enable command processing on its own.
#
# This mirrors the SLSA ecosystem-specific Go builder
# (builder_go_slsa3.yml). See docs/SLSA_L3_AUDIT.md Finding 3.
#
# The stop-commands state is job-scoped: the GitHub Actions runner's
# ActionCommandManager is a per-job singleton with no per-step reset, so
# `::stop-commands::` emitted in one step stays in effect for every later
# step until the matching token is emitted. The guard therefore MUST
# always re-enable command processing — leaving it suspended would
# silently disable `::add-mask::` secret redaction for the rest of the
# job. Subcommands:
#
#   run <command> [args...]
#       Suspend commands, run <command>, then ALWAYS re-enable (even when
#       the command exits non-zero), preserving the command's exit
#       status. Use this to wrap a single build/test script invocation
#       inside one `run:` step.
#
#   begin
#       Generate a token, write `stop-commands-token=<token>` to
#       $GITHUB_OUTPUT, and emit `::stop-commands::<token>`. Use this in
#       a step that precedes a `uses:` build step which cannot be wrapped
#       in-process (e.g. docker/build-push-action). The matching `end`
#       MUST run in a later step.
#
#   end <token>
#       Emit `::<token>::` to re-enable command processing. A no-op when
#       <token> is empty, so an `if: always()` cleanup step is safe even
#       when the `begin` step was skipped by an earlier failure.
#
# Usage: lib/stop_commands_guard.sh <run|begin|end> [args...]

set -euo pipefail
set -f  # disable globbing — processes externally-supplied arguments

# 32 bytes of kernel CSPRNG output, hex-encoded (a 256-bit token). `od`
# reads an exact byte count and exits 0, so there is no SIGPIPE/pipefail
# hazard (unlike `tr -dc < /dev/urandom | head`, where head closing the
# pipe early would trip pipefail).
generate_token() {
    od -vN32 -An -tx1 /dev/urandom | tr -d '[:space:]'
}

case "${1:-}" in
    run)
        shift
        if [[ $# -eq 0 ]]; then
            printf 'Usage: %s run <command> [args...]\n' "$0" >&2
            exit 1
        fi
        token="$(generate_token)"
        printf '::stop-commands::%s\n' "$token"
        # `|| status=$?` makes the wrapped command a tested command, so
        # `set -e` does not abort here on a non-zero exit — the re-enable
        # line below MUST be reached on every code path.
        status=0
        "$@" || status=$?
        printf '::%s::\n' "$token"
        exit "$status"
        ;;
    begin)
        if [[ $# -ne 1 ]]; then
            printf 'Usage: %s begin\n' "$0" >&2
            exit 1
        fi
        if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
            printf 'Error: begin requires GITHUB_OUTPUT to be set\n' >&2
            exit 1
        fi
        token="$(generate_token)"
        # $GITHUB_OUTPUT is a file the runner reads after the step; it is
        # not the `::set-output::` stdout command, so this write is
        # unaffected by stop-commands. The docker build cannot read step
        # outputs, so the token stays unguessable to the guarded build.
        printf 'stop-commands-token=%s\n' "$token" >> "$GITHUB_OUTPUT"
        printf '::stop-commands::%s\n' "$token"
        ;;
    end)
        if [[ $# -ne 2 ]]; then
            printf 'Usage: %s end <token>\n' "$0" >&2
            exit 1
        fi
        token="$2"
        # No-op on an empty token: the `end` step runs with `if: always()`
        # so it still fires when an earlier failure skipped `begin`, in
        # which case there is no suspended state to re-enable.
        if [[ -n "$token" ]]; then
            printf '::%s::\n' "$token"
        fi
        ;;
    *)
        printf 'Usage: %s <run|begin|end> [args...]\n' "$0" >&2
        exit 1
        ;;
esac
