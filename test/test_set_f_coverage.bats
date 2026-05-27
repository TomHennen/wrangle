#!/usr/bin/env bats

# Meta-test: every shell script in wrangle that processes positional
# arguments (`$1`, `$2`, `$@`, `$*`, or their `${...}` forms) MUST set
# `set -f` before those arguments are consumed. See CLAUDE.md
# "Shell Script Safety" and issue #244.
#
# Why this lives at the top of test/ and not inside per-script test.bats:
# a future PR adding a new script under `tools/`, `lib/`, `actions/`,
# `build/`, or `test/integration/` could ship without `set -f` and every
# existing per-script test would still pass — the script-level argument-
# globbing hole would slip through silently. This meta-test enumerates
# the source tree and fails if a new script is added without disabling
# globbing.
#
# The audit predicate matches the one used to derive #244's scope:
# scripts that declare `set -euo pipefail` AND reference `$1`/`$2`/`$@`/
# `$*` (or their `${...}` forms). Scripts that don't take positional
# arguments — pure function libs sourced into other shells — are not
# required to `set -f` because the option would leak into the caller's
# shell (see lib/sanitize.sh for the canonical "no `set -euo pipefail`,
# pure function lib" exemption).

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    # Explicit allowlist of scripts that intentionally do NOT `set -f`.
    # Add a script here ONLY with a rationale in the comment justifying
    # why argument globbing is impossible or already mitigated.
    #
    # Paths are relative to REPO_ROOT.
    #
    # TRANSITIONAL EXEMPTIONS — to be removed when PR #243
    # (wrangle-shell-lint) lands. #243's WSL002 rule bulk-adds `set -f`
    # to every shell script as part of an atomic rewrite (see also PR
    # #271, which makes `set -f` the project-wide default). Listing the
    # 12 currently-non-compliant scripts here lets this meta-test land
    # ahead of #243 without blocking CI, while still catching brand-new
    # scripts added in the interim. When #243 lands and removes the
    # `set -f` gap, this array should be emptied in the same commit
    # that removes the gap.
    EXEMPT_SCRIPTS=(
        "test.sh"
        "lib/download_verify.sh"
        "lib/tool_banner.sh"
        "test/integration/dispatch.sh"
        "tools/osv/install.sh"
        "tools/syft/install.sh"
        "tools/scorecard/sarif_to_markdown.sh"
        "build/actions/python/install_deps.sh"
        "build/actions/python/run_tests.sh"
        "build/actions/npm/detect_tooling.sh"
        "build/actions/npm/build_and_pack.sh"
        "build/actions/npm/validate_inputs.sh"
    )
}

is_exempt() {
    local rel="$1"
    for exempt in "${EXEMPT_SCRIPTS[@]}"; do
        [[ "$rel" == "$exempt" ]] && return 0
    done
    return 1
}

@test "set-f-coverage: every arg-processing shell script disables globbing" {
    # Enumerate every *.sh in the repo (excluding .git, the test-runner
    # container build artifacts, and the bats test files themselves —
    # those use the bats `run` helper, not raw $1/$2).
    local missing=()
    local f rel
    while IFS= read -r f; do
        rel="${f#"$REPO_ROOT"/}"

        # Predicate 1: script opts into strict mode. Pure function libs
        # without `set -euo pipefail` (e.g., lib/sanitize.sh) are sourced
        # into the caller's shell where `set -f` would leak; they are out
        # of scope by construction.
        grep -q 'set -euo pipefail' "$f" || continue

        # Predicate 2: script references positional arguments.
        grep -qE '\$[12@*]|\$\{[12@*]' "$f" || continue

        # Predicate 3: script disables globbing somewhere before use.
        # Match either `set -f` at column 0 (the project convention from
        # CLAUDE.md) or indented after `set -euo pipefail` — both are
        # acceptable, the position-anchored form keeps the audit deterministic.
        if grep -qE '^[[:space:]]*set -f([[:space:]]|$)' "$f"; then
            continue
        fi

        if is_exempt "$rel"; then
            continue
        fi

        missing+=("$rel")
    done < <(find "$REPO_ROOT" \
        -type d \( -name .git -o -name node_modules \) -prune -o \
        -type f -name '*.sh' -print)

    if (( ${#missing[@]} > 0 )); then
        printf 'Shell scripts processing arguments without `set -f`:\n' >&2
        printf '  - %s\n' "${missing[@]}" >&2
        printf '\n' >&2
        printf 'Add `set -f` immediately after `set -euo pipefail` (see\n' >&2
        printf 'CLAUDE.md "Shell Script Safety" and issue #244). If the\n' >&2
        printf 'script genuinely cannot disable globbing, add the path to\n' >&2
        printf 'EXEMPT_SCRIPTS in %s with a written rationale.\n' \
            "$BATS_TEST_FILENAME" >&2
        return 1
    fi
}

@test "set-f-coverage: predicate finds at least one script (sanity check)" {
    # If the predicate matches nothing the test above is meaningless.
    # The repo has many arg-processing scripts; require at least 5 to
    # guard against a typo that breaks the predicate.
    local count=0
    local f
    while IFS= read -r f; do
        grep -q 'set -euo pipefail' "$f" || continue
        grep -qE '\$[12@*]|\$\{[12@*]' "$f" || continue
        count=$((count + 1))
    done < <(find "$REPO_ROOT" \
        -type d \( -name .git -o -name node_modules \) -prune -o \
        -type f -name '*.sh' -print)
    [[ "$count" -ge 5 ]]
}
