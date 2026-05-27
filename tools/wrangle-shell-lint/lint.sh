#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes file paths passed as arguments

# tools/wrangle-shell-lint/lint.sh — Wrangle shell-style linter.
# Enforces CLAUDE.md shell conventions not covered by shellcheck.
#
# Rules implemented here (shellcheck gaps):
#   WSL001  first substantive (non-shebang, non-comment, non-blank) line
#           must be exactly the literal string: set -euo pipefail
#           (intentionally strict — see note below)
#   WSL002  scripts that iterate over "$@" in a for-loop, or named adapter.sh,
#           must also contain: set -f
#           NOTE: this is a best-effort heuristic. CLAUDE.md requires set -f
#           for any script that "processes arguments from external input" —
#           a broader set than this rule catches. Reviewers must still verify
#           manually for while-shift loops, $1/$2 positional consumers, etc.
#   WSL003  echo with variable interpolation: use printf instead
#           (only flags `echo` as a command at statement start or after a
#           command separator, and only when an unescaped $ in a double-quoted
#           or unquoted context follows — see check_wsl003 for details)
#   WSL004  single-bracket [ ] or `test` used as a conditional: use [[ ]] instead
#           Detects: `if/while/until [ ...`, bare `[ ... ]` as a statement,
#           and `test ...` as a statement. Skips comment-only lines.
#   WSL005  # shellcheck disable without an inline justification comment
#
# Rules already enforced by shellcheck (NOT re-implemented here):
#   SC2006  backtick command substitution
#   SC2086  unquoted variable expansions
#
# Out of scope (CLAUDE.md rules NOT enforced by this linter):
#   - "Inline Shell in GitHub Actions" — inline `run:` blocks longer than
#     ~5 lines or containing logic should be extracted to scripts. This is
#     a YAML-level rule and would require a separate YAML scanner.
#   - "GitHub Actions Expression Injection" — `${{ inputs.* }}` or
#     `${{ github.event.* }}` interpolated directly into `run:` blocks.
#     actionlint does not flag this by default; a dedicated YAML rule is
#     needed. Tracked as a follow-up; see PR #243 review discussion.
#
# Note on WSL001 exactness: stricter forms like `set -Eeuo pipefail` (adds
# ERR trap inheritance) and equivalent forms like `set -e -u -o pipefail`
# are intentionally rejected. The rule enforces a single canonical preamble
# across the codebase. If you need ERR trap inheritance, add a separate
# `set -E` line after `set -euo pipefail`.
#
# Output: path:line: WSLxxx: message  (one per violation, to stdout)
# Exit  : 0 if clean, 1 if any violations found
#
# Usage:
#   lint.sh                   walk the repo (excludes the linter's own fixtures)
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
                "first substantive line must be exactly 'set -euo pipefail' (no equivalents or stricter forms; see lint.sh header) (got: ${line:0:60})"
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

# WSL003: ban echo with variable interpolation.
# Flags only when `echo` is the command being invoked AND the line contains
# an unescaped `$` outside of single-quoted text — i.e. a real variable
# expansion. Filters out:
#   - comment-only lines (start with #)
#   - subword matches like `xecho`
#   - `echo` appearing inside string arguments to other commands
#   - escaped `\$`
#   - `$` inside single-quoted segments (literal, no expansion)
#   - lines inside single-quoted heredoc bodies (<<'TAG' / <<"TAG"),
#     which have no parameter expansion
# Detected statement-start contexts (where `echo` is the command):
#   - line start, or after one of: ; | & ( { ) ` && ||
#   - after a control-flow keyword on the same line: then / do / else
# Note: shell tokenisation in awk/regex is approximate. A few exotic
# constructs (mixed quoting, nested command substitutions starting on the
# same line) may still slip through or false-fire; the heuristic is tuned
# for the common case where the rest of wrangle's code lives.
check_wsl003() {
    local file="$1"
    while IFS= read -r lineno; do
        emit "$file" "$lineno" "WSL003" \
            "use printf instead of echo for output containing variables"
    done < <(awk '
        # Track quoted-heredoc state so literal `echo $foo` text inside a
        # <<'\''TAG'\'' or <<"TAG" body is not flagged. Unquoted heredocs
        # (<<TAG) DO expand variables, so we still lint those.
        function in_quoted_heredoc() { return heredoc_tag != "" }

        {
            # If we are inside a quoted heredoc, only the terminating tag
            # line is meaningful; everything else is literal text.
            if (in_quoted_heredoc()) {
                # Heredoc terminator: tag on a line by itself, optional
                # leading tabs only if <<- was used. We accept either,
                # because the linter is best-effort.
                tag = heredoc_tag
                if ($0 == tag || $0 ~ ("^[\t]+" tag "$")) {
                    heredoc_tag = ""
                }
                next
            }

            # Detect the START of a quoted heredoc on this line. Patterns:
            #   <<'\''TAG'\''   <<"TAG"   <<-'\''TAG'\''   <<-"TAG"
            # We capture TAG and switch to heredoc-skip mode for subsequent
            # lines. We still process the current line normally for echo.
            if (match($0, /<<-?[[:space:]]*'\''[A-Za-z_][A-Za-z0-9_]*'\''/) ||
                match($0, /<<-?[[:space:]]*"[A-Za-z_][A-Za-z0-9_]*"/)) {
                s = substr($0, RSTART, RLENGTH)
                # Strip leading <<, optional -, whitespace, and surrounding quote.
                sub(/^<<-?[[:space:]]*['\''""]/, "", s)
                sub(/['\''""]$/, "", s)
                heredoc_tag = s
            }
        }

        # Skip comment-only lines.
        /^[[:space:]]*#/ { next }

        {
            line = $0

            # Strip single-quoted segments (no variable expansion inside).
            # Repeatedly remove pairs of single quotes and what is between
            # them; this is a regex approximation, not a real lexer.
            while (match(line, /'\''[^'\'']*'\''/)) {
                line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
            }

            # Strip trailing inline comments (best-effort: # preceded by
            # whitespace or at the start of the remaining string).
            sub(/[[:space:]]+#.*$/, "", line)

            # Strip escaped dollars so they are not seen as expansions.
            gsub(/\\\$/, "", line)

            # Require an unescaped $ to remain — i.e. real expansion.
            if (index(line, "$") == 0) next

            # Require `echo` to appear as a command:
            #   - at the start of the (left-trimmed) statement, or
            #   - immediately after a command separator:
            #       ; | & ( { ) ` && ||
            #     ( `)` covers case-arms;  `(` and `` ` `` cover command
            #     substitutions starting on the same line. )
            #   - immediately after a control-flow keyword that introduces
            #     a command on the same line: then / do / else
            # Word-anchor on both sides so xecho / echoes do not match.
            if (match(line, /(;|\||&&|\|\||\(|\{|\)|`)[[:space:]]*echo([[:space:]]|$)/) ||
                match(line, /(^|[[:space:]])(then|do|else)[[:space:]]+echo([[:space:]]|$)/) ||
                match(line, /^[[:space:]]*echo([[:space:]]|$)/)) {
                print NR
            }
        }
    ' "$file")
}

# WSL004: single-bracket conditionals or `test` command.
# Flags:
#   - if/elif/while/until followed by [ (single bracket, not [[)
#   - bare [ as a statement (e.g. `[ -n "$x" ] && do_thing`)
#   - bare `test` as a statement (alias of `[`)
# Skips comment-only lines.
check_wsl004() {
    local file="$1"
    while IFS= read -r lineno; do
        emit "$file" "$lineno" "WSL004" \
            "use [[ ]] instead of [ ] or 'test' for conditionals"
    done < <(awk '
        # Skip comment-only lines.
        /^[[:space:]]*#/ { next }

        {
            line = $0

            # Strip single-quoted segments so brackets inside literals are ignored.
            while (match(line, /'\''[^'\'']*'\''/)) {
                line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
            }
            # Strip trailing inline comments.
            sub(/[[:space:]]+#.*$/, "", line)

            # if/elif/while/until [ (not [[)
            if (match(line, /(^|[[:space:]]|;|&&|\|\|)(if|elif|while|until)[[:space:]]+\[[^[]/)) {
                print NR; next
            }
            # bare [ as a statement: starts the line/statement, followed by space.
            # Anchored to: line start, ; , && , || , or `then`/`do`/`else` separators.
            if (match(line, /(^|[[:space:]]*;[[:space:]]*|[[:space:]]+&&[[:space:]]+|[[:space:]]+\|\|[[:space:]]+|^[[:space:]]*(then|do|else)[[:space:]]+)\[[[:space:]]/) &&
                !match(line, /(^|[[:space:]]*;[[:space:]]*|[[:space:]]+&&[[:space:]]+|[[:space:]]+\|\|[[:space:]]+|^[[:space:]]*(then|do|else)[[:space:]]+)\[\[/)) {
                print NR; next
            }
            # bare `test` as a statement.
            if (match(line, /(^|[[:space:]]*;[[:space:]]*|[[:space:]]+&&[[:space:]]+|[[:space:]]+\|\|[[:space:]]+|^[[:space:]]*(then|do|else)[[:space:]]+)test[[:space:]]/)) {
                print NR; next
            }
        }
    ' "$file")
}

# WSL005: shellcheck disable must include an inline justification comment.
# Justified:   "# shellcheck disable=SC2016 # reason text"
# Unjustified: "# shellcheck disable=SC2016" (nothing after the code — this is flagged)
# Trailing whitespace after the disable code does not count as justification
# (and is itself a style issue, but we report it under WSL005 with a clear
# remediation hint rather than a separate rule).
check_wsl005() {
    local file="$1"
    while IFS= read -r lineno; do
        emit "$file" "$lineno" "WSL005" \
            "add a justification comment after the disable code: '# shellcheck disable=SCXXXX # <reason>'"
    done < <(awk '
        # Find: leading whitespace, "# shellcheck disable=CODES", optional
        # trailing whitespace, end of line. Trailing whitespace is stripped
        # before matching so an editor-added space/tab does not change the
        # error message.
        {
            line = $0
            sub(/[[:space:]]+$/, "", line)
            if (line ~ /# shellcheck disable=[A-Z0-9,]+$/) {
                print NR
            }
        }
    ' "$file")
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
    # Walk all regular files and filter via is_shell_script so that
    # extensionless bash scripts (e.g. a `bin/wrangle` wrapper detected by
    # shebang) are linted with the same rules as `*.sh` files. This keeps
    # the repo-walk path consistent with the explicit-args path above.
    while IFS= read -r -d '' file; do
        if is_shell_script "$file"; then
            check_file "$file"
        fi
    done < <(find "$repo_root" -type f \
        -not -path '*/.git/*' \
        -not -path '*/.beads/*' \
        -not -path '*/wrangle-shell-lint/fixtures/*' \
        -print0 | sort -z)
fi

if [[ "$found_violations" == true ]]; then
    exit 1
fi
exit 0
