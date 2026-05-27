#!/bin/bash
set -euo pipefail
set -f

# tools/wrangle-shell-lint/lint.sh — Wrangle shell-style linter.
#
# Thin wrapper around `ast-grep scan` with the WSL001-005 rules under
# `tools/wrangle-shell-lint/rules/`. The rules enforce CLAUDE.md shell
# conventions that shellcheck does not cover:
#
#   WSL001  first substantive line must be exactly: set -euo pipefail
#   WSL002  second substantive line must be exactly: set -f
#   WSL003  echo with variable expansion — use printf instead
#   WSL004  [ ] or `test` used as a conditional — use [[ ]] instead
#   WSL005  # shellcheck disable=... without an inline justification
#
# Rules already enforced by shellcheck (NOT re-implemented):
#   SC2006  backtick command substitution
#   SC2086  unquoted variable expansions
#
# Out of scope (CLAUDE.md rules NOT enforced by this linter):
#   - "Inline Shell in GitHub Actions" length cap
#   - "GitHub Actions Expression Injection" — actionlint does not flag
#     ${{ inputs.* }} interpolated into run: blocks by default
#   Tracked as follow-up: see PR #243 for the issue link.
#
# Why ast-grep: the previous awk/grep implementation produced both
# false positives and false negatives across heredocs, case arms,
# subword matches like `xecho`, and `[` inside string literals. AST
# matching via tree-sitter-bash eliminates this entire class of bug
# because the linter sees the parsed shell tree, not raw bytes.
#
# Usage:
#   lint.sh                   walk the repo (excludes the linter's own fixtures)
#   lint.sh <file> [...]      lint specific files only
#
# Exit: 0 if clean, 1 if any violations found, 2 if ast-grep is missing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SGCONFIG="${SCRIPT_DIR}/sgconfig.yml"

# Locate ast-grep. Prefer $WRANGLE_BIN_DIR (where install.sh places it)
# but fall back to anything on $PATH so local developers who installed
# via `brew install ast-grep` or `cargo install` aren't forced through
# the wrangle install script.
#
# When falling back to PATH, log which binary and which version we
# picked so CI logs make it obvious if the pinned install.sh binary
# wasn't used (PR #243 review 4369032065 / comment 3308126456).
ast_grep_bin=""
ast_grep_source=""
if [[ -n "${WRANGLE_BIN_DIR:-}" && -x "${WRANGLE_BIN_DIR}/ast-grep" ]]; then
    ast_grep_bin="${WRANGLE_BIN_DIR}/ast-grep"
    ast_grep_source="WRANGLE_BIN_DIR"
elif command -v ast-grep >/dev/null 2>&1; then
    ast_grep_bin="$(command -v ast-grep)"
    ast_grep_source="PATH"
fi

if [[ -z "$ast_grep_bin" ]]; then
    printf 'wrangle-shell-lint: ast-grep not found.\n' >&2
    printf 'wrangle-shell-lint: install via tools/wrangle-shell-lint/install.sh\n' >&2
    printf 'wrangle-shell-lint: or place ast-grep on PATH.\n' >&2
    exit 2
fi

if [[ "$ast_grep_source" == "PATH" ]]; then
    ast_grep_version="$("$ast_grep_bin" --version 2>/dev/null | head -n1 || true)"
    printf 'wrangle-shell-lint: using ast-grep from PATH: %s (%s)\n' \
        "$ast_grep_bin" "${ast_grep_version:-version unknown}" >&2
    printf 'wrangle-shell-lint: set WRANGLE_BIN_DIR to the pinned install dir for CI parity.\n' >&2
fi

# is_shell_script: true if $1 is a *.sh file or an extensionless file
# whose first line is a bash shebang. Matches the file-discovery rules
# of the explicit-args path and the repo-walk path so a future
# extensionless `bin/wrangle` wrapper is linted with the same rules as
# the `*.sh` files. See round-2 review thread 3307715530.
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

# Collect target files into an array. The result is the union of:
#   - the user's explicit args (filtered to shell scripts), OR
#   - all *.sh + extensionless shebang scripts in the repo.
declare -a targets=()
if [[ $# -gt 0 ]]; then
    for arg in "$@"; do
        if is_shell_script "$arg"; then
            targets+=("$arg")
        fi
    done
else
    repo_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || \
        repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
    while IFS= read -r -d '' f; do
        if is_shell_script "$f"; then
            targets+=("$f")
        fi
    done < <(find "$repo_root" -type f \
        -not -path '*/.git/*' \
        -not -path '*/.beads/*' \
        -not -path '*/wrangle-shell-lint/fixtures/*' \
        -print0 | sort -z)
fi

if [[ ${#targets[@]} -eq 0 ]]; then
    exit 0
fi

# Extensionless shebang scripts are not auto-associated with the bash
# parser by ast-grep (its file-language matching is extension-based).
# To run the rules over them, symlink each extensionless target into a
# tmp staging dir with a `.sh` suffix, then ast-grep treats it as bash.
# `.sh`-named targets are linted in place — no symlink, no copy.
#
# Why this approach over a stdin-pipe loop: ast-grep's --stdin mode
# only supports one rule at a time, which would mean five passes per
# file. The staging-dir approach is one ast-grep invocation total,
# which is dramatically faster and produces unified output.

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wrangle-shell-lint-XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

# For each target, decide whether to symlink it under STAGE_DIR or
# scan it in place. Build a parallel array of paths that ast-grep will
# actually see. We also build a reverse map so we can rewrite ast-grep
# output paths back to the user-visible source paths (so error
# messages point at the real file, not the symlink in STAGE_DIR).
declare -a scan_paths=()
declare -a real_paths=()
for t in "${targets[@]}"; do
    if [[ "$t" == *.sh ]]; then
        scan_paths+=("$t")
        real_paths+=("$t")
    else
        # Hash the original path to produce a unique stage filename so
        # two scripts with the same basename don't collide.
        hash="$(printf '%s' "$t" | sha1sum | cut -c1-12)"
        base="$(basename "$t")"
        stage="${STAGE_DIR}/${hash}-${base}.sh"
        # Resolve $t to an absolute path before symlinking. A relative
        # path passed by the caller would become a relative-target
        # symlink that doesn't resolve from inside STAGE_DIR, causing
        # ast-grep to print `ERROR: ... No such file or directory` to
        # stderr but still exit 0 — a silent fail-open.
        # See PR #243 review 4369032065 / comment 3308126441.
        abs_t="$(readlink -f "$t" 2>/dev/null || true)"
        if [[ -z "$abs_t" || ! -e "$abs_t" ]]; then
            printf 'wrangle-shell-lint: cannot resolve %s\n' "$t" >&2
            exit 2
        fi
        ln -s "$abs_t" "$stage"
        scan_paths+=("$stage")
        real_paths+=("$t")
    fi
done

# Run ast-grep across all staged paths in one invocation. --error
# elevates every rule's severity to error so the exit code is 1 on
# any finding. --report-style short keeps the output as one line per
# finding: <path>:<line>:<col>: <severity>[<rule-id>]: <message>
#
# Capture stdout (findings) and stderr (tool errors) separately. We
# MUST inspect stderr: ast-grep can exit 0 while writing `ERROR: ...`
# to stderr (e.g. unresolvable file path, unreadable file). For a
# security linter, fail-closed on tool error is mandatory — silently
# treating those as pass is a fail-open bug (PR #243 review 4369032065
# / comment 3308126441; CLAUDE.md Adapter Contract analogue).
ast_grep_stdout_file="$(mktemp "${STAGE_DIR}/stdout.XXXXXX")"
ast_grep_stderr_file="$(mktemp "${STAGE_DIR}/stderr.XXXXXX")"
"$ast_grep_bin" scan \
    -c "$SGCONFIG" \
    --error \
    --report-style short \
    "${scan_paths[@]}" \
    >"$ast_grep_stdout_file" 2>"$ast_grep_stderr_file" && ast_grep_status=0 || ast_grep_status=$?

ast_grep_stdout="$(cat "$ast_grep_stdout_file")"
ast_grep_stderr="$(cat "$ast_grep_stderr_file")"

# Rewrite any STAGE_DIR/<hash>-<base>.sh paths back to the source path
# the user passed in. The hash prefix is the SHA-1 (first 12 chars) of
# the original path, so the mapping is unambiguous. Applied to both
# stdout (findings) and stderr (errors) so messages point at real files.
rewrite_paths() {
    local s="$1"
    local i sp rp
    for i in "${!scan_paths[@]}"; do
        sp="${scan_paths[$i]}"
        rp="${real_paths[$i]}"
        if [[ "$sp" != "$rp" ]]; then
            # Use parameter expansion to avoid double-substitution if a
            # real path happens to look like a stage path.
            s="${s//${sp}/${rp}}"
        fi
    done
    printf '%s' "$s"
}

if [[ -n "$ast_grep_stdout" ]]; then
    printf '%s\n' "$(rewrite_paths "$ast_grep_stdout")"
fi

# Fail-closed on ERROR: lines in stderr regardless of exit status. The
# anchor `^ERROR:` matches ast-grep's stderr error format precisely
# (unresolvable path, unreadable file, parser load failure, etc.).
if printf '%s' "$ast_grep_stderr" | grep -q '^ERROR:'; then
    printf '%s\n' "$(rewrite_paths "$ast_grep_stderr")" >&2
    printf 'wrangle-shell-lint: ast-grep reported tool errors (see above); failing closed.\n' >&2
    exit 2
fi

# If stderr has any other content (warnings, progress), surface it too
# so it's visible in CI logs — but only fail on the ERROR: case above.
if [[ -n "$ast_grep_stderr" ]]; then
    printf '%s\n' "$(rewrite_paths "$ast_grep_stderr")" >&2
fi

# ast-grep returns 0 on clean, 1 on any error-level finding, 2-3 on
# tool/usage errors. Map the latter to our exit 2 (tool error).
case "$ast_grep_status" in
    0) exit 0 ;;
    1) exit 1 ;;
    *) exit 2 ;;
esac
