#!/usr/bin/env bats

# Structural tests asserting that every reusable workflow in
# .github/workflows/ wires the preflight guard correctly. The guard's
# own refusal-logic tests live next to the action source in
# actions/preflight_guard/test.bats — this file only checks the
# workflow-level wiring:
#
#   1. The first job under `jobs:` is `guard:`.
#   2. The `guard:` job has `permissions: {}` (least privilege).
#   3. The `guard:` job invokes `actions/preflight_guard` via `uses:`.
#   4. Every other job lists `guard` in its `needs:` so a refused
#      invocation skips the entire workflow.
#
# Grep-based; doesn't parse YAML. Tests break loudly if anyone refactors
# the guard wiring out or accidentally adds a new job without the
# `needs: [guard]` dependency.

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

@test "wiring: reusable-workflow discovery is non-empty" {
    # Fail closed: a broken glob or wrong dir would otherwise make every
    # per-workflow assertion below pass vacuously over an empty list.
    [[ "${#REUSABLE_WORKFLOWS[@]}" -gt 0 ]] || {
        printf 'No reusable workflows discovered in %s\n' "$WORKFLOWS_DIR" >&2
        return 1
    }
}

@test "wiring: first job in each reusable workflow is guard" {
    # Defense against accidentally reordering the guard below a job that
    # could side-effect before the refusal fires.
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        first_job=$(awk '
            /^jobs:$/                                  { in_jobs=1; next }
            in_jobs && /^  [a-zA-Z][a-zA-Z0-9_-]*:$/   {
                name=$1; sub(":", "", name); print name; exit
            }
        ' "$WORKFLOWS_DIR/$wf")
        [[ "$first_job" == "guard" ]] || {
            printf "First job in %s is '%s' not 'guard'\n" "$wf" "$first_job" >&2
            return 1
        }
    done
}

@test "wiring: guard job invokes actions/preflight_guard via uses:" {
    for wf in "${REUSABLE_WORKFLOWS[@]}"; do
        guard_block=$(awk '
            /^  guard:$/             { in_block=1; print; next }
            in_block && /^  [a-z]/   { in_block=0 }
            in_block                 { print }
        ' "$WORKFLOWS_DIR/$wf")
        echo "$guard_block" | grep -qE 'uses:[[:space:]]*TomHennen/wrangle/actions/preflight_guard@' || {
            printf 'guard job in %s does not use TomHennen/wrangle/actions/preflight_guard\n' "$wf" >&2
            printf '%s\n' "$guard_block" >&2
            return 1
        }
    done
}

@test "wiring: guard job has permissions: {}" {
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

@test "wiring: every non-guard job lists guard in its needs" {
    # Failing the guard must skip every downstream job. The cheapest
    # invariant to grep is "every non-guard job's needs: includes guard".
    # Transitive gating via gate/build would also work, but the explicit
    # form is easier to audit at a glance and breaks loudly if a later
    # job is added without the guard dependency.
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
            [[ "$job" == "guard" ]] && continue
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
