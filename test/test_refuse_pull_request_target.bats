#!/usr/bin/env bats

# Structural tests for the pull_request_target refusal guard added per
# issue #202. Every reusable workflow in .github/workflows/ that adopters
# can `uses:` must:
#
#   1. Declare a `guard` job at the head of `jobs:`.
#   2. Give that job `permissions: {}` (least privilege).
#   3. Run a step that fails on `pull_request_target` and
#      `workflow_run`-triggered-by-`pull_request_target` events.
#   4. Have every other job include `guard` in its `needs:` list, so
#      a refused invocation skips the entire workflow.
#
# These are grep-based — they don't parse YAML. The pwn-request comment,
# error string fingerprint, and exact `permissions: {}` literal are the
# load-bearing checks. Tests will break loudly if anyone refactors the
# guard out or accidentally loosens its permissions.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
    REUSABLE_WORKFLOWS=(
        "build_and_publish_npm.yml"
        "build_and_publish_python.yml"
        "build_and_publish_container.yml"
        "build_shell.yml"
        "check_source_change.yml"
    )
}

@test "guard: every reusable workflow has a guard job" {
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        grep -qE '^  guard:$' "$WORKFLOWS_DIR/$wf" || {
            printf 'Missing guard: job in %s\n' "$wf" >&2
            return 1
        }
    done
}

@test "guard: pull_request_target string is checked by name" {
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        grep -qF '"$EVENT_NAME" == "pull_request_target"' "$WORKFLOWS_DIR/$wf" || {
            printf 'Direct pull_request_target check missing in %s\n' "$wf" >&2
            return 1
        }
    done
}

@test "guard: workflow_run triggered by pull_request_target is also refused" {
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        grep -qF '"$EVENT_NAME" == "workflow_run"' "$WORKFLOWS_DIR/$wf" || {
            printf 'workflow_run check missing in %s\n' "$wf" >&2
            return 1
        }
        grep -qF '"$OUTER_EVENT" == "pull_request_target"' "$WORKFLOWS_DIR/$wf" || {
            printf 'workflow_run.event == pull_request_target check missing in %s\n' "$wf" >&2
            return 1
        }
    done
}

@test "guard: error message references the pwn-request vector" {
    # Fingerprint that survives editorial polish but breaks if the guard
    # is silently swapped for a no-op `exit 0` step.
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        grep -qF "'pwn request' vector" "$WORKFLOWS_DIR/$wf" || {
            printf 'pwn-request fingerprint missing in %s\n' "$wf" >&2
            return 1
        }
    done
}

@test "guard: job has permissions: {}" {
    # Inspect only the guard job's block. The block starts at `  guard:`
    # and ends at the next top-level job (two-space-indented `<name>:`).
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        guard_block=$(awk '
            /^  guard:$/             { in_block=1; print; next }
            in_block && /^  [a-z]/   { in_block=0 }
            in_block                 { print }
        ' "$WORKFLOWS_DIR/$wf")
        echo "$guard_block" | grep -qE 'permissions: \{\}' || {
            printf 'guard job in %s missing permissions: {}\n' "$wf" >&2
            printf '%s\n' "$guard_block" >&2
            return 1
        }
    done
}

@test "guard: every non-guard job lists guard in its needs" {
    # Failing the guard must skip every downstream job. The cheapest
    # invariant to grep is "every non-guard job's needs: includes guard".
    # Transitive gating via gate/build would also work, but the explicit
    # form is easier to audit at a glance and breaks loudly if a later
    # job is added without the guard dependency.
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        # Extract top-level job names (two-space-indented `<name>:`).
        jobs=$(awk '
            /^jobs:$/                                  { in_jobs=1; next }
            in_jobs && /^[a-zA-Z]/                     { in_jobs=0 }
            in_jobs && /^  [a-zA-Z][a-zA-Z0-9_-]*:$/   {
                name=$1; sub(":", "", name); print name
            }
        ' "$WORKFLOWS_DIR/$wf")
        [ -n "$jobs" ] || {
            printf 'No jobs found in %s — awk extraction broken?\n' "$wf" >&2
            return 1
        }
        for job in $jobs; do
            [ "$job" = "guard" ] && continue
            # Pull lines from `  <job>:` until the next top-level job
            # declaration.
            block=$(awk -v j="$job" '
                $0 == "  " j ":"                       { in_job=1; print; next }
                in_job && /^  [a-zA-Z][a-zA-Z0-9_-]*:$/ { in_job=0 }
                in_job                                 { print }
            ' "$WORKFLOWS_DIR/$wf")
            echo "$block" | grep -qE '^[[:space:]]*needs:.*\[.*\bguard\b.*\]' || {
                printf "Job '%s' in %s does not list 'guard' in its needs:\n" "$job" "$wf" >&2
                printf '%s\n' "$block" >&2
                return 1
            }
        done
    done
}

@test "guard: no reusable workflow checks the event before guard runs" {
    # Defense against accidentally reordering the guard so another job
    # could side-effect before the refusal fires. The guard job MUST be
    # the first top-level entry under `jobs:` in each reusable workflow.
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        first_job=$(awk '
            /^jobs:$/                                  { in_jobs=1; next }
            in_jobs && /^  [a-zA-Z][a-zA-Z0-9_-]*:$/   {
                name=$1; sub(":", "", name); print name; exit
            }
        ' "$WORKFLOWS_DIR/$wf")
        [ "$first_job" = "guard" ] || {
            printf "First job in %s is '%s' not 'guard'\n" "$wf" "$first_job" >&2
            return 1
        }
    done
}
