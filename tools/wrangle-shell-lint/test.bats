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

@test "WSL003: subword like xecho is not flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\nx="$1"\nxecho() { printf "%%s" "$1"; }\nxecho "$x"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL003"* ]]
}

@test "WSL003: 'echo' inside string arg to another command is not flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\nvar="x"\nerror_msg="Failed to echo $var"\nprintf "%%s" "$error_msg"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL003"* ]]
}

@test "WSL003: echo with single-quoted literal dollar is not flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf "#!/bin/bash\nset -euo pipefail\nset -f\necho 'literal \$foo'\n" > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL003"* ]]
}

@test "WSL003: echo with escaped backslash-dollar is not flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\necho "literal \\$1"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL003"* ]]
}

@test "WSL003: echo after case-arm ')' is reported" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\ncase x in y) echo "$y";; esac\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL003"* ]]
}

@test "WSL003: echo after 'then' on same line is reported" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\nx=1\nif true; then echo "$x"\nfi\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL003"* ]]
}

@test "WSL003: echo with variable inside backticks is reported" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    # shellcheck disable=SC2016 # literal backtick string for fixture content
    printf '#!/bin/bash\nset -euo pipefail\nset -f\nbar=1\nfoo="`echo $bar`"\nprintf "%%s" "$foo"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL003"* ]]
}

@test "WSL003: 'echo \$var' literal inside single-quoted heredoc is not flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf "#!/bin/bash\nset -euo pipefail\nset -f\ncat <<'NOEXP'\necho \$var literal\nNOEXP\n" > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL003"* ]]
}

@test "WSL003: 'echo \$var' inside double-quoted heredoc tag is not flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\ncat <<"NOEXP"\necho $var literal\nNOEXP\n' > "$tmp"
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

@test "WSL004: comment mentioning [ ] is not flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\n# Old code used: if [ -n "$x" ]; then ...\nprintf done\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL004"* ]]
}

@test "WSL004: bare [ statement is reported" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\n[ -n "$1" ] && printf "yes\\n"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL004"* ]]
}

@test "WSL004: bare test statement is reported" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\ntest -n "$1" && printf "yes\\n"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL004"* ]]
}

@test "WSL004: elif [ ] is reported" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\nif true; then :\nelif [ -n "$1" ]; then :\nfi\n' > "$tmp"
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

@test "WSL005: trailing whitespace after disable code is still flagged" {
    # An editor's whitespace-trim toggle can add trailing spaces/tabs; the
    # rule must not treat that as a justification. See review id 4368542425.
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\n# shellcheck disable=SC2016   \nprintf done\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL005"* ]]
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

# --- Repo walk -------------------------------------------------------------

@test "repo walk lints extensionless shebang scripts" {
    # Confirm the repo-walk path uses is_shell_script (matching the
    # explicit-args path) so a future extensionless `bin/wrangle` script
    # is not silently skipped. We exercise this by creating a temp git
    # repo with an extensionless shebang script that violates WSL001.
    tmp_repo="$(mktemp -d /tmp/wsl-repo-XXXXXX)"
    git -C "$tmp_repo" init -q
    # Make the lint.sh discoverable as a sibling tree so SCRIPT_DIR's
    # `git rev-parse` returns this tmp_repo as the repo root.
    mkdir -p "$tmp_repo/tools/wrangle-shell-lint"
    cp "$LINTER" "$tmp_repo/tools/wrangle-shell-lint/lint.sh"
    # Extensionless bash script missing `set -euo pipefail` (WSL001).
    cat > "$tmp_repo/runme" << 'SCRIPT'
#!/bin/bash
printf 'hi\n'
SCRIPT
    chmod +x "$tmp_repo/runme"
    run "$tmp_repo/tools/wrangle-shell-lint/lint.sh"
    rm -rf "$tmp_repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"runme"* ]]
    [[ "$output" == *"WSL001"* ]]
}
