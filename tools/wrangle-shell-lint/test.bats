#!/usr/bin/env bats

# Tests for tools/wrangle-shell-lint/lint.sh.
#
# One positive fixture per rule (script that violates the rule → lint flags it)
# and a shared negative fixture (clean script → lint passes cleanly).
# Fixtures live in tools/wrangle-shell-lint/fixtures/ and are excluded from
# the repo-wide scan so their intentional violations don't fail CI.

setup() {
    ORIG_DIR="$(pwd)"
    LINTER="$ORIG_DIR/tools/wrangle-shell-lint/lint.sh"
    FIXTURES="$ORIG_DIR/tools/wrangle-shell-lint/fixtures"
    export ORIG_DIR LINTER FIXTURES
}

teardown() {
    cd "$ORIG_DIR" || true
}

# --- Negative fixture: clean script passes all rules -------------------------

@test "clean script: no violations reported" {
    run "$LINTER" "$FIXTURES/good.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- WSL001: set -euo pipefail at top ----------------------------------------

@test "WSL001: missing set -euo pipefail is reported" {
    run "$LINTER" "$FIXTURES/bad_wsl001.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL001"* ]]
}

@test "WSL001: correct set -euo pipefail is not flagged" {
    run "$LINTER" "$FIXTURES/good.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL001"* ]]
}

@test "WSL001: set -euo pipefail after comments is accepted" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\n# Comment line\n\nset -euo pipefail\nprintf hello\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL001"* ]]
}

@test "WSL001: wrong first substantive line is flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nFOO=bar\nset -euo pipefail\nprintf hello\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL001"* ]]
}

# --- WSL002: set -f for external input ---------------------------------------

@test "WSL002: for-loop over \$@ without set -f is reported" {
    run "$LINTER" "$FIXTURES/bad_wsl002.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL002"* ]]
}

@test "WSL002: for-loop over \$@ with set -f is not flagged" {
    run "$LINTER" "$FIXTURES/good.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL002"* ]]
}

@test "WSL002: adapter.sh without set -f is reported" {
    tmp_dir="$(mktemp -d /tmp/wsl-test-XXXXXX)"
    cat > "$tmp_dir/adapter.sh" << 'SCRIPT'
#!/bin/bash
set -euo pipefail
printf 'adapter\n'
SCRIPT
    run "$LINTER" "$tmp_dir/adapter.sh"
    rm -rf "$tmp_dir"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL002"* ]]
}

@test "WSL002: adapter.sh with set -f is not flagged" {
    tmp_dir="$(mktemp -d /tmp/wsl-test-XXXXXX)"
    cat > "$tmp_dir/adapter.sh" << 'SCRIPT'
#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input
printf 'adapter\n'
SCRIPT
    run "$LINTER" "$tmp_dir/adapter.sh"
    rm -rf "$tmp_dir"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL002"* ]]
}

# --- WSL003: echo with variable interpolation --------------------------------

@test "WSL003: echo with variable is reported" {
    run "$LINTER" "$FIXTURES/bad_wsl003.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL003"* ]]
}

@test "WSL003: printf with variable is not flagged" {
    run "$LINTER" "$FIXTURES/good.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL003"* ]]
}

@test "WSL003: echo with no variable is not flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\necho "static text"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL003"* ]]
}

@test "WSL003: commented-out echo with variable is not flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\n# echo "$var"\nprintf done\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL003"* ]]
}

# --- WSL004: [ ] not [[ ]] ---------------------------------------------------

@test "WSL004: if [ ] is reported" {
    run "$LINTER" "$FIXTURES/bad_wsl004.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL004"* ]]
}

@test "WSL004: if [[ ]] is not flagged" {
    run "$LINTER" "$FIXTURES/good.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL004"* ]]
}

@test "WSL004: while [ ] is reported" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\nwhile [ "$x" -gt 0 ]; do x=$((x-1)); done\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL004"* ]]
}

# --- WSL005: shellcheck disable without justification ------------------------

@test "WSL005: shellcheck disable without inline justification is reported" {
    run "$LINTER" "$FIXTURES/bad_wsl005.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL005"* ]]
}

@test "WSL005: shellcheck disable with inline justification is not flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    # shellcheck disable=SC2016 # backticks are literal markdown spans
    printf '#!/bin/bash\nset -euo pipefail\nset -f\n# shellcheck disable=SC2016 # backticks are markdown, not command subs\nprintf "ok"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL005"* ]]
}

# --- Output format -----------------------------------------------------------

@test "output format is path:line: RULE: message" {
    run "$LINTER" "$FIXTURES/bad_wsl001.sh"
    [ "$status" -eq 1 ]
    # Check that at least one line matches the expected format
    found=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[^:]+:[0-9]+:\ WSL[0-9]+:\ .+ ]]; then
            found=true
            break
        fi
    done <<< "$output"
    [ "$found" = true ]
}

# --- Self-check: linter passes its own rules ---------------------------------

@test "lint.sh itself passes all wrangle-shell-lint rules" {
    run "$LINTER" "$LINTER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
