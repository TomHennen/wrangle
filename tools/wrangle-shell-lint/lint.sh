#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes file paths passed as arguments

# tools/wrangle-shell-lint/lint.sh — Wrangle shell-style linter.
# Enforces CLAUDE.md shell conventions not covered by shellcheck.
#
# Rules implemented here (shellcheck gaps):
#   WSL001  first substantive (non-shebang, non-comment, non-blank) line
#           must be exactly: set -euo pipefail
#   WSL002  scripts that iterate over "$@" in a for-loop, or named adapter.sh,
#           must also contain: set -f  (narrow heuristic; see PR description)
#   WSL003  echo with variable interpolation: use printf instead
#   WSL004  if/while/until with [ ] single-bracket: use [[ ]] instead
#   WSL005  # shellcheck disable without an inline justification comment
#
# Rules already enforced by shellcheck (NOT re-implemented here):
#   SC2006  backtick command substitution
#   SC2086  unquoted variable expansions
#
# Output: path:line: WSLxxx: message  (one per violation, to stdout)
# Exit  : 0 if clean, 1 if any violations found
#
# Usage:
#   lint.sh                   walk the repo (excludes fixtures/ directories)
#   lint.sh <file> [...]      lint specific files only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

found_violations=false

emit() {
    local file="$1" lineno="$2" rule="$3"
    shift 3
    printf '%s:%s: %s: %s\n' "$file" "$lineno" "$rule" "$*"
    found_violations=true
}

# WSL001: first substantive line must be exactly "set -euo pipefail".
# Substantive = not shebang, not blank, not comment-only.
check_wsl001() {
    local file="$1"
    local lineno=0 line first_found=false
    # shellcheck disable=SC2094 # emit only writes to stdout, not to $file; the loop only reads it
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        [[ $lineno -eq 1 && "$line" == '#!'* ]] && continue
        [[ -z "$line" || "$line" == '#'* ]] && continue
        first_found=true
        if [[ "$line" != "set -euo pipefail" ]]; then
            emit "$file" "$lineno" "WSL001" \
                "first substantive line must be 'set -euo pipefail' (got: ${line:0:60})"
        fi
        break
    done < "$file"
    if [[ "$first_found" == false ]]; then
        emit "$file" "1" "WSL001" \
            "no substantive lines found — missing 'set -euo pipefail'"
    fi
}

# WSL002: narrow heuristic for set -f requirement.
# Flags scripts that iterate "$@" in a for-loop, or are named adapter.sh,
# but do not contain "set -f". Scripts that process external input via
# simple $1/$2 positional args (without a for-over-$@ loop) are not
# flagged — the heuristic is deliberately conservative to avoid false
# positives on install scripts, helper scripts, and build action scripts.
check_wsl002() {
    local file="$1"
    # Already has set -f — compliant.
    grep -qE '^[[:space:]]*set -f' "$file" && return 0

    # Trigger 1: for loop over "$@"
    if grep -qP 'for [a-zA-Z_][a-zA-Z_0-9]* in "\$@"' "$file"; then
        local lineno
        lineno=$(grep -nP 'for [a-zA-Z_][a-zA-Z_0-9]* in "\$@"' "$file" | head -1 | cut -d: -f1)
        emit "$file" "$lineno" "WSL002" \
            "script iterates over \"\$@\" but lacks 'set -f' (add: set -f  # disable globbing — processes external input)"
        return
    fi

    # Trigger 2: adapter scripts always process external src/output paths
    if [[ "$(basename "$file")" == "adapter.sh" ]]; then
        emit "$file" "1" "WSL002" \
            "adapter.sh processes external paths but lacks 'set -f'"
    fi
}

# WSL003: hard ban on echo with variable interpolation.
# Flags any non-comment line where "echo" (as a word) precedes content
# containing "$". Use printf instead for all output that may contain
# user-controlled data.
check_wsl003() {
    local file="$1"
    while IFS= read -r lineno; do
        emit "$file" "$lineno" "WSL003" \
            "use printf instead of echo for output containing variables"
    done < <(awk '
        /^[[:space:]]*#/ { next }
        /echo[[:space:]]/ && /\$/ { print NR }
    ' "$file")
}

# WSL004: single-bracket conditionals.
# Flags if/while/until followed by [ (single bracket, not [[).
check_wsl004() {
    local file="$1"
    while IFS= read -r lineno; do
        emit "$file" "$lineno" "WSL004" \
            "use [[ ]] instead of [ ] for conditionals"
    done < <(grep -nP '\b(if|while|until)[[:space:]]+\[(?!\[)' "$file" | cut -d: -f1)
}

# WSL005: shellcheck disable must include an inline justification comment.
# Justified:   "# shellcheck disable=SC2016 # reason text"
# Unjustified: "# shellcheck disable=SC2016" (nothing after the code — this is flagged)
check_wsl005() {
    local file="$1"
    while IFS= read -r lineno; do
        emit "$file" "$lineno" "WSL005" \
            "# shellcheck disable must have an inline justification (e.g. '# shellcheck disable=SCXXXX # reason')"
    done < <(grep -nP '# shellcheck disable=[A-Z0-9,]+[[:space:]]*$' "$file" | cut -d: -f1)
}

check_file() {
    local file="$1"
    check_wsl001 "$file"
    check_wsl002 "$file"
    check_wsl003 "$file"
    check_wsl004 "$file"
    check_wsl005 "$file"
}

is_shell_script() {
    local file="$1"
    [[ "$file" == *.sh ]] && return 0
    local firstline
    firstline=$(head -n1 "$file" 2>/dev/null) || return 1
    case "$firstline" in
        '#!/bin/bash'*|'#!/usr/bin/env bash'*) return 0 ;;
    esac
    return 1
}

if [[ $# -gt 0 ]]; then
    for file in "$@"; do
        if is_shell_script "$file"; then
            check_file "$file"
        fi
    done
else
    repo_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || \
        repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
    while IFS= read -r -d '' file; do
        check_file "$file"
    done < <(find "$repo_root" -name '*.sh' \
        -not -path '*/.git/*' \
        -not -path '*/.beads/*' \
        -not -path '*/fixtures/*' \
        -print0 | sort -z)
fi

if [[ "$found_violations" == true ]]; then
    exit 1
fi
exit 0
