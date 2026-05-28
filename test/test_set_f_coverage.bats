#!/usr/bin/env bats

# Meta-test: every shell script in wrangle that processes positional
# arguments MUST `set -f` before those arguments are consumed. A new
# script could otherwise slip through without globbing disabled and
# every per-script test would still pass.
#
# Predicate: scripts that declare `set -euo pipefail` AND reference
# `$1`/`$2`/`$@`/`$*` (or `${...}` forms). Pure function libs sourced
# into other shells are excluded — they'd leak the option to callers.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    # Transitional exemptions: scripts pre-dating the project-wide
    # `set -f` default. The shell-style linter's bulk update will add
    # `set -f` to all of these in a single atomic change; this list
    # must be emptied in that same commit. Until then it lets the
    # meta-test land without blocking CI while still catching newly
    # added scripts.
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

        # Strict-mode opt-in. Pure libs without it are sourced where
        # `set -f` would leak to the caller — out of scope by construction.
        grep -q 'set -euo pipefail' "$f" || continue

        # References positional arguments.
        grep -qE '\$[12@*]|\$\{[12@*]' "$f" || continue

        # Disables globbing (either column 0 or indented).
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
        printf 'CLAUDE.md "Shell scripts"). If the script genuinely cannot\n' >&2
        printf 'disable globbing, add the path to EXEMPT_SCRIPTS in %s\n' \
            "$BATS_TEST_FILENAME" >&2
        printf 'with a written rationale.\n' >&2
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
