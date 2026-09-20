#!/bin/bash
set -euo pipefail
set -f

# release_preflight.sh — run every code-level gate that must hold before a
# release tag is cut, and report one line per gate.
#
# The tag is immutable once created, so a check that fires on the tag is too
# late: the frozen tag already embeds whatever digests were there.
# This runs at the last point where they are settled but still mutable — right
# before `gh release create` (the cut-release skill drives it).
#
# A gate that cannot reach its backend (exit 2) reports UNVERIFIED and fails the
# run: an unproven precondition is not a satisfied one.
#
# The showcase gate judges the wrangle-test showcase by its latest completed
# tracking-tag run (read-only; never re-runs the workflow — remedy for a red
# run is a human re-running it, #839).
#
# Wrangle's own scheduled freshness workflows are deliberately not gated the
# same way — the live checks below already re-derive freshness against the
# current catalog, which a run-history check can't improve on (#839).
#
# Gates that need a human or a live run against the release content stay in
# the skill, not here: milestone hygiene, a live showcase run for the actual
# release commit, and the verifying_artifacts.md recipes.
#
# Exit: 0 every gate passed, 1 a gate failed or could not be verified.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# name|script — order runs cheap/offline gates before the ones that hit a registry.
WRANGLE_RELEASE_GATES=(
    "curated tool images digest-pinned and default-closed|check_catalog.sh"
    "curated tool images not behind :latest|check_catalog_freshness.sh"
    "curated tool image digests built from current source|check_catalog_provenance_freshness.sh"
    "wrangle-test showcase's last completed run is green|check_showcase_run_green.sh"
)

# Run one gate, echoing its own output (which carries the remediation) when it
# does not pass. Returns the gate's exit code.
wrangle_run_gate() {
    local name="$1" script="$2"
    local out rc=0

    out="$("$SCRIPT_DIR/$script" 2>&1)" || rc=$?

    case "$rc" in
        0) printf 'PASS        %s\n' "$name" ;;
        2) printf 'UNVERIFIED  %s\n' "$name" ;;
        *) printf 'FAIL        %s\n' "$name" ;;
    esac
    if [[ "$rc" -ne 0 && -n "$out" ]]; then
        printf '%s\n' "$out" | sed 's/^/            /'
    fi
    return "$rc"
}

wrangle_release_preflight() {
    local entry name script rc failed=0

    printf 'release preflight — code-level gates\n\n'
    for entry in "${WRANGLE_RELEASE_GATES[@]}"; do
        name="${entry%%|*}"
        script="${entry#*|}"
        rc=0
        wrangle_run_gate "$name" "$script" || rc=$?
        [[ "$rc" -ne 0 ]] && failed=$((failed + 1))
    done

    printf '\n'
    if [[ "$failed" -ne 0 ]]; then
        printf 'release preflight: %d of %d gate(s) not satisfied — do not cut the tag.\n' \
            "$failed" "${#WRANGLE_RELEASE_GATES[@]}" >&2
        return 1
    fi
    printf 'release preflight: all %d gate(s) satisfied.\n' "${#WRANGLE_RELEASE_GATES[@]}"
    printf 'Still owner-run (see the cut-release skill): milestone hygiene, a live showcase\n'
    printf 'run against the release commit, and the docs/verifying_artifacts.md recipes\n'
    printf 'against a real artifact.\n'
}

main() {
    wrangle_release_preflight
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
