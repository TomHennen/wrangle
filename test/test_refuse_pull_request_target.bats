#!/usr/bin/env bats

# Structural tests asserting that every reusable workflow in
# .github/workflows/ wires the preflight guard correctly. The guard's
# own refusal-logic tests live in test/test_preflight_guard.bats; prep's
# guard-first ordering is in actions/prep/test.bats. This file only checks
# the workflow-level
# wiring — every reusable workflow heads with the `prep` job:
#
#   1. The first job under `jobs:` is `prep`.
#   2. The `prep` job has `permissions: {}` (least privilege).
#   3. The `prep` job invokes `actions/prep` via `uses:`.
#   4. Every other job lists `prep` in its `needs:` so a refused
#      invocation skips the entire workflow.
#
# Grep-based; doesn't parse YAML. Tests break loudly if anyone refactors
# the guard wiring out or accidentally adds a new job without the
# `needs: [prep]` dependency.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"

    # Auto-discover reusable workflows (those that declare `workflow_call`) so a
    # newly added reusable workflow is guard-checked without editing a list that
    # silently drifts. A reusable workflow that legitimately needs no guard goes
    # in EXEMPT with a rationale.
    EXEMPT_REUSABLE_WORKFLOWS=()
    REUSABLE_WORKFLOWS=()
    while IFS= read -r -d '' wf; do
        grep -qE '^[[:space:]]*workflow_call:' "$wf" || continue
        name="$(basename "$wf")"
        for ex in "${EXEMPT_REUSABLE_WORKFLOWS[@]}"; do
            [[ "$name" == "$ex" ]] && continue 2
        done
        REUSABLE_WORKFLOWS+=("$name")
    done < <(find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.yml' -type f -print0 | sort -z)
}

# The `<job>:` block (its lines, up to the next top-level job).
job_block() {
    awk -v j="$2" '
        $0 == "  " j ":"                        { in_block=1; print; next }
        in_block && /^  [a-zA-Z][a-zA-Z0-9_-]*:$/ { in_block=0 }
        in_block                                { print }
    ' "$1"
}

@test "wiring: reusable-workflow discovery is non-empty" {
    # Fail closed: a broken glob or wrong dir would otherwise make every
    # per-workflow assertion below pass vacuously over an empty list.
    [[ "${#REUSABLE_WORKFLOWS[@]}" -gt 0 ]] || {
        printf 'No reusable workflows discovered in %s\n' "$WORKFLOWS_DIR" >&2
        return 1
    }
}

@test "wiring: first job in each reusable workflow is prep" {
    # Defense against accidentally reordering the guard below a job that
    # could side-effect before the refusal fires.
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        first_job=$(awk '
            /^jobs:$/                                  { in_jobs=1; next }
            in_jobs && /^  [a-zA-Z][a-zA-Z0-9_-]*:$/   {
                name=$1; sub(":", "", name); print name; exit
            }
        ' "$WORKFLOWS_DIR/$wf")
        [[ "$first_job" == "prep" ]] || {
            printf "First job in %s is '%s' not 'prep'\n" "$wf" "$first_job" >&2
            return 1
        }
    done
}

@test "wiring: prep job invokes actions/prep via uses:" {
    # The preflight guard runs as prep's first step (asserted in
    # actions/prep/test.bats).
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        block="$(job_block "$WORKFLOWS_DIR/$wf" prep)"
        echo "$block" | grep -qE 'uses:[[:space:]]*TomHennen/wrangle/actions/prep@' || {
            printf 'prep job in %s does not use TomHennen/wrangle/actions/prep\n' "$wf" >&2
            printf '%s\n' "$block" >&2
            return 1
        }
    done
}

@test "wiring: prep job has permissions: {}" {
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        block="$(job_block "$WORKFLOWS_DIR/$wf" prep)"
        echo "$block" | grep -qE 'permissions: \{\}' || {
            printf 'prep job in %s missing permissions: {}\n' "$wf" >&2
            printf '%s\n' "$block" >&2
            return 1
        }
    done
}

@test "wiring: every non-prep job lists prep in its needs" {
    # Failing the guard must skip every downstream job. The cheapest
    # invariant to grep is "every non-prep job's needs: includes prep".
    # Transitive gating would also work, but the explicit form is easier
    # to audit at a glance and breaks loudly if a later job is added
    # without the prep dependency.
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        jobs=$(awk '
            /^jobs:$/                                  { in_jobs=1; next }
            in_jobs && /^[a-zA-Z]/                     { in_jobs=0 }
            in_jobs && /^  [a-zA-Z][a-zA-Z0-9_-]*:$/   {
                name=$1; sub(":", "", name); print name
            }
        ' "$WORKFLOWS_DIR/$wf")
        [[ -n "$jobs" ]] || {
            printf 'No jobs found in %s — awk extraction broken?\n' "$wf" >&2
            return 1
        }
        for job in $jobs; do
            [[ "$job" == "prep" ]] && continue
            block="$(job_block "$WORKFLOWS_DIR/$wf" "$job")"
            echo "$block" | grep -qE '^[[:space:]]*needs:.*\[.*\bprep\b.*\]' || {
                printf "Job '%s' in %s does not list 'prep' in its needs:\n" "$job" "$wf" >&2
                printf '%s\n' "$block" >&2
                return 1
            }
        done
    done
}
