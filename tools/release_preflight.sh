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
# The wrangle-test showcase is judged by its own run history (the latest
# completed tracking-tag run) rather than re-derived locally: nobody watches
# it, so it went red for three weeks unnoticed (#839). It never re-runs the
# workflow — a red run blocks with its URL, and the remedy is a human
# re-running it.
#
# Deliberately NOT gated the same way: wrangle's own scheduled freshness runs
# (catalog_freshness.yml / catalog_provenance_freshness.yml). A run-history
# check for them would be strictly weaker than the two live gates already
# below — those re-derive freshness against the CURRENT catalog, so they catch
# drift a stale green run-history would miss — and, unlike the showcase's
# tracking tags, a freshness workflow's failed run replays the OLD commit on
# re-run, so "re-run it" can never clear a run that already merged a fix.
# wrangle-alert issues (raised by the scheduled workflows themselves) cover
# "nobody noticed" for these instead.
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
