#!/usr/bin/env bats

# Structural tests asserting that every reusable workflow in
# .github/workflows/ wires the preflight guard correctly. The guard's
# own refusal-logic tests live next to the action source in
# actions/preflight_guard/test.bats — this file only checks the
# workflow-level wiring:
#
#   1. The first job under `jobs:` is the head job — `guard` (runs the
#      guard directly) or `prep` (runs the guard as its first step; see
#      actions/prep/test.bats for the ordering guarantee).
#   2. The head job has `permissions: {}` (least privilege).
#   3. The head job invokes preflight_guard (guard) or prep via `uses:`.
#   4. Every other job lists the head job in its `needs:` so a refused
#      invocation skips the entire workflow.
#
# Grep-based; doesn't parse YAML. Tests break loudly if anyone refactors
# the guard wiring out or accidentally adds a new job without the
# head-job dependency.

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

# First job under `jobs:` — the head job that gates the rest.
head_job() {
    awk '
        /^jobs:$/                                  { in_jobs=1; next }
        in_jobs && /^  [a-zA-Z][a-zA-Z0-9_-]*:$/   {
            name=$1; sub(":", "", name); print name; exit
        }
    ' "$1"
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

@test "wiring: first job in each reusable workflow is the guard or prep head job" {
    # Defense against accidentally reordering the guard below a job that
    # could side-effect before the refusal fires.
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        first_job="$(head_job "$WORKFLOWS_DIR/$wf")"
        [[ "$first_job" == "guard" || "$first_job" == "prep" ]] || {
            printf "First job in %s is '%s' not 'guard' or 'prep'\n" "$wf" "$first_job" >&2
            return 1
        }
    done
}

@test "wiring: head job invokes preflight_guard or prep via uses:" {
    # The guard runs directly (guard job) or as prep's first step. prep's
    # guard-first ordering is asserted in actions/prep/test.bats.
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        head="$(head_job "$WORKFLOWS_DIR/$wf")"
        block="$(job_block "$WORKFLOWS_DIR/$wf" "$head")"
        echo "$block" | grep -qE 'uses:[[:space:]]*TomHennen/wrangle/actions/(preflight_guard|prep)@' || {
            printf 'head job in %s does not use preflight_guard or prep\n' "$wf" >&2
            printf '%s\n' "$block" >&2
            return 1
        }
    done
}

@test "wiring: head job has permissions: {}" {
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        head="$(head_job "$WORKFLOWS_DIR/$wf")"
        block="$(job_block "$WORKFLOWS_DIR/$wf" "$head")"
        echo "$block" | grep -qE 'permissions: \{\}' || {
            printf 'head job in %s missing permissions: {}\n' "$wf" >&2
            printf '%s\n' "$block" >&2
            return 1
        }
    done
}

@test "wiring: every non-head job lists the head job in its needs" {
    # Failing the guard must skip every downstream job. The cheapest
    # invariant to grep is "every non-head job's needs: includes the head
    # job". Transitive gating would also work, but the explicit form is
    # easier to audit at a glance and breaks loudly if a later job is
    # added without the head-job dependency.
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        head="$(head_job "$WORKFLOWS_DIR/$wf")"
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
            [[ "$job" == "$head" ]] && continue
            block="$(job_block "$WORKFLOWS_DIR/$wf" "$job")"
            echo "$block" | grep -qE "^[[:space:]]*needs:.*\[.*\b${head}\b.*\]" || {
                printf "Job '%s' in %s does not list '%s' in its needs:\n" "$job" "$wf" "$head" >&2
                printf '%s\n' "$block" >&2
                return 1
            }
        done
    done
}
