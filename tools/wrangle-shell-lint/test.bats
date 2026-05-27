#!/usr/bin/env bats

# Tests for tools/wrangle-shell-lint/lint.sh — the ast-grep-based linter
# that enforces CLAUDE.md shell conventions not covered by shellcheck.
#
# Layout:
#   - One positive fixture per rule under fixtures/ (committed) that
#     each violate exactly their rule.
#   - good.sh (committed) is the negative fixture — must pass cleanly.
#   - Inline tmp-file fixtures cover edge cases surfaced in the PR #243
#     review rounds 1-3.
#
# These tests exercise the wrapper end-to-end (which invokes ast-grep).
# ast-grep must be on PATH or in $WRANGLE_BIN_DIR — the test container's
# Dockerfile preinstalls it via tools/wrangle-shell-lint/install.sh.

setup() {
    ORIG_DIR="$(pwd)"
    LINTER="$ORIG_DIR/tools/wrangle-shell-lint/lint.sh"
    FIXTURES="$ORIG_DIR/tools/wrangle-shell-lint/fixtures"
    export ORIG_DIR LINTER FIXTURES

    # Skip every test if ast-grep is not installed. We do this rather
    # than auto-installing inside the bats run because the install
    # script downloads from the internet — a flaky test failure would
    # be misattributed to the linter. The CI image's Dockerfile is
    # responsible for installing ast-grep up front.
    if [[ -z "${WRANGLE_BIN_DIR:-}" || ! -x "${WRANGLE_BIN_DIR}/ast-grep" ]]; then
        if ! command -v ast-grep >/dev/null 2>&1; then
            skip "ast-grep not installed — run tools/wrangle-shell-lint/install.sh first"
        fi
    fi
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
    printf '#!/bin/bash\n# Comment line\n\nset -euo pipefail\nset -f\nprintf hello\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL001"* ]]
}

@test "WSL001: wrong first substantive line is flagged" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nFOO=bar\nset -euo pipefail\nset -f\nprintf hello\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL001"* ]]
}

@test "WSL001: stricter form set -Eeuo pipefail is rejected" {
    # Stricter (adds ERR trap inheritance) but still rejected per the
    # rule's exact-string design. See lint.sh / wsl001.yml header.
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -Eeuo pipefail\nset -f\nprintf hello\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL001"* ]]
}

@test "WSL001: equivalent form set -e -u -o pipefail is rejected" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -e -u -o pipefail\nset -f\nprintf hello\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL001"* ]]
}

# --- WSL002: set -f as the second substantive line (UNIVERSAL per #271) -----

@test "WSL002: missing set -f after preamble is reported" {
    run "$LINTER" "$FIXTURES/bad_wsl002.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL002"* ]]
}

@test "WSL002: set -f as second line is not flagged" {
    run "$LINTER" "$FIXTURES/good.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL002"* ]]
}

@test "WSL002: set -f with trailing comment on the same line is not flagged" {
    # The AST node's text covers just the command, not the trailing
    # comment — so the exact-string regex matches.
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f  # processes external input\nprintf hello\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL002"* ]]
}

@test "WSL002: arbitrary script without set -f is reported (universal rule)" {
    # Per PR #271 (universal set -f), ANY script missing set -f on line
    # 2 is a violation — not just adapter.sh or for-over-$@ scripts.
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nprintf hello\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL002"* ]]
}

@test "WSL002: an internal set +f wrap is not flagged (escape hatch)" {
    # The escape hatch is `set +f` / `set -f` wrapped around a glob.
    # The wrap appears INSIDE the script, never at position 2, so the
    # WSL002 rule does not flag it. The preamble line at position 2 is
    # still required and present here.
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    cat > "$tmp" << 'SCRIPT'
#!/bin/bash
set -euo pipefail
set -f
# set +f: this loop intentionally expands the glob
set +f
shopt -s nullglob
for f in /etc/*.conf; do
    printf '%s\n' "$f"
done
set -f
SCRIPT
    run "$LINTER" "$tmp"
    rm -f "$tmp"
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

@test "WSL003: echo with command substitution \$(...) is reported" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\necho "$(date)"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL003"* ]]
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
    printf '#!/bin/bash\nset -euo pipefail\nset -f\nx=1\nwhile [ "$x" -gt 0 ]; do x=$((x-1)); done\n' > "$tmp"
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

@test "WSL004: array index [0] is not flagged" {
    # array[0] is not a test_command — it's an arithmetic subscript.
    # AST matching correctly distinguishes the two.
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\narr=(a b c)\nprintf "%%s" "${arr[0]}"\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WSL004"* ]]
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

@test "WSL005: multiple codes without justification is reported" {
    tmp="$(mktemp /tmp/wsl-test-XXXXXX.sh)"
    printf '#!/bin/bash\nset -euo pipefail\nset -f\n# shellcheck disable=SC2016,SC2086\nprintf done\n' > "$tmp"
    run "$LINTER" "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WSL005"* ]]
}

# --- Output format -----------------------------------------------------------

@test "output format includes path, line, and rule id" {
    run "$LINTER" "$FIXTURES/bad_wsl001.sh"
    [ "$status" -eq 1 ]
    # ast-grep emits: <path>:<line>:<col>: <severity>[<rule-id>]: <message>
    found=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[^:]+:[0-9]+:[0-9]+:\ error\[wsl[0-9]+ ]]; then
            found=true
            break
        fi
    done <<< "$output"
    [ "$found" = true ]
}

# --- Self-check: linter itself passes its own rules --------------------------

@test "lint.sh itself passes all wrangle-shell-lint rules" {
    run "$LINTER" "$LINTER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "install.sh itself passes all wrangle-shell-lint rules" {
    run "$LINTER" "$ORIG_DIR/tools/wrangle-shell-lint/install.sh"
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
    # Make the lint.sh + rules + sgconfig discoverable as a sibling tree
    # so SCRIPT_DIR's `git rev-parse` returns this tmp_repo as the root.
    mkdir -p "$tmp_repo/tools/wrangle-shell-lint/rules"
    cp "$LINTER" "$tmp_repo/tools/wrangle-shell-lint/lint.sh"
    cp "$ORIG_DIR/tools/wrangle-shell-lint/sgconfig.yml" "$tmp_repo/tools/wrangle-shell-lint/sgconfig.yml"
    cp "$ORIG_DIR/tools/wrangle-shell-lint/rules"/*.yml "$tmp_repo/tools/wrangle-shell-lint/rules/"
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
