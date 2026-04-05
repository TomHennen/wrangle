#!/bin/bash
set -euo pipefail
set -f  # disable globbing — tool names come from external input

# Wrangle orchestrator — installs and runs security tool adapters.
#
# Usage: run.sh [-s <src_dir>] [-o <output_dir>] <tool1> [tool2] ...
#
# Exit codes:
#   0  All tools passed with no findings
#   1  At least one tool found issues
#   2  At least one tool failed to run (includes invalid tool names)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source env.sh to add WRANGLE_BIN_DIR to PATH so adapters find
# installed tool binaries.
# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

TOOLS_DIR="${WRANGLE_TOOLS_DIR:-${SCRIPT_DIR}/tools}"

# Defaults
src_dir="."
output_dir="./metadata"

# Parse options
while getopts "s:o:" opt; do
    case "$opt" in
        s) src_dir="$OPTARG" ;;
        o) output_dir="$OPTARG" ;;
        *) printf 'Usage: run.sh [-s <src_dir>] [-o <output_dir>] <tool1> [tool2] ...\n' >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

# Require at least one tool
if [[ $# -eq 0 ]]; then
    printf 'Usage: run.sh [-s <src_dir>] [-o <output_dir>] <tool1> [tool2] ...\n' >&2
    exit 2
fi

# Parse tool specs: strip :policy suffixes, collect adapter-pattern tools.
# Action-pattern tools (have a directory but no adapter.sh) are skipped.
# Unknown tools (no directory at all) are rejected.
TOOL_NAME_RE='^[a-z][a-z0-9_-]*$'
declare -a adapter_tools=()
for spec in "$@"; do
    tool="${spec%%:*}"
    if [[ ! "$tool" =~ $TOOL_NAME_RE ]]; then
        printf 'wrangle: invalid tool name: %s (must match %s)\n' "$tool" "$TOOL_NAME_RE" >&2
        exit 2
    fi
    if [[ ! -d "${TOOLS_DIR}/${tool}" ]]; then
        printf 'wrangle: unknown tool: %s (no directory at %s/%s/)\n' "$tool" "$TOOLS_DIR" "$tool" >&2
        exit 2
    fi
    if [[ -f "${TOOLS_DIR}/${tool}/adapter.sh" ]] && [[ -f "${TOOLS_DIR}/${tool}/install.sh" ]]; then
        adapter_tools+=("$tool")
    fi
done

if [[ ${#adapter_tools[@]} -eq 0 ]]; then
    printf 'wrangle: no adapter-pattern tools to run\n'
    exit 0
fi

mkdir -p "$output_dir"

# Track overall status: 0=clean, 1=findings, 2=error
overall_status=0

# Timeout defaults (seconds)
INSTALL_TIMEOUT="${WRANGLE_INSTALL_TIMEOUT:-300}"
ADAPTER_TIMEOUT="${WRANGLE_ADAPTER_TIMEOUT:-600}"

# Summary tracking
declare -a summary_tools=()
declare -a summary_statuses=()

for tool in "${adapter_tools[@]}"; do
    printf '::group::wrangle/%s\n' "$tool"
    printf 'wrangle: === %s ===\n' "$tool"

    tool_status="pass"

    # Step 1: Install
    printf 'wrangle: installing %s...\n' "$tool"
    install_exit=0
    timeout "$INSTALL_TIMEOUT" "${TOOLS_DIR}/${tool}/install.sh" || install_exit=$?

    if [[ "$install_exit" -eq 124 ]]; then
        printf 'wrangle: %s install timed out after %ds\n' "$tool" "$INSTALL_TIMEOUT" >&2
    elif [[ "$install_exit" -ne 0 ]]; then
        printf 'wrangle: install failed for %s (exit %d)\n' "$tool" "$install_exit" >&2
    fi
    if [[ "$install_exit" -ne 0 ]]; then
        tool_status="error"
        overall_status=2
        summary_tools+=("$tool")
        summary_statuses+=("$tool_status")
        continue
    fi

    # Step 2: Create output directory
    tool_output_dir="${output_dir}/${tool}"
    mkdir -p "$tool_output_dir"

    # Step 3: Snapshot workspace for post-execution filesystem check
    # Records file paths, sizes, and mtimes to detect additions, removals, and modifications
    pre_snapshot="$(mktemp "${TMPDIR:-/tmp}/wrangle-pre-XXXXX")"
    # Exclude output_dir from snapshot — when metadata dir is inside src_dir
    # (workspace-relative), adapter writes there are expected, not rogue.
    find "$src_dir" -not -path "${output_dir}/*" -type f -printf '%p %s %T@\n' 2>/dev/null | sort > "$pre_snapshot" || true

    # Step 4: Run adapter with isolated environment
    printf 'wrangle: running %s...\n' "$tool"
    adapter_exit=0

    # Build restricted environment: only allowlisted variables + WRANGLE_EXTRA_*
    adapter_env=(
        "PATH=${PATH}"
        "HOME=${HOME:-}"
        "TMPDIR=${TMPDIR:-/tmp}"
        "RUNNER_TEMP=${RUNNER_TEMP:-}"
        "GITHUB_WORKSPACE=${GITHUB_WORKSPACE:-}"
        "GITHUB_STEP_SUMMARY=${GITHUB_STEP_SUMMARY:-}"
    )
    # Forward WRANGLE_EXTRA_* variables with prefix stripped
    while IFS='=' read -r key value; do
        if [[ "$key" == WRANGLE_EXTRA_* ]]; then
            stripped_key="${key#WRANGLE_EXTRA_}"
            adapter_env+=("${stripped_key}=${value}")
        fi
    done < <(env)

    timeout "$ADAPTER_TIMEOUT" env -i "${adapter_env[@]}" \
        "${TOOLS_DIR}/${tool}/adapter.sh" "$src_dir" "$tool_output_dir" || adapter_exit=$?

    # Step 5: Post-execution filesystem check
    post_snapshot="$(mktemp "${TMPDIR:-/tmp}/wrangle-post-XXXXX")"
    find "$src_dir" -not -path "${output_dir}/*" -type f -printf '%p %s %T@\n' 2>/dev/null | sort > "$post_snapshot" || true
    if ! diff -q "$pre_snapshot" "$post_snapshot" >/dev/null 2>&1; then
        printf 'wrangle: WARNING: %s modified files outside its output directory\n' "$tool" >&2
    fi
    rm -f "$pre_snapshot" "$post_snapshot"

    case "$adapter_exit" in
        0)
            tool_status="pass"
            ;;
        1)
            tool_status="findings"
            if [[ "$overall_status" -lt 1 ]]; then
                overall_status=1
            fi
            ;;
        124)
            # timeout(1) returns 124 when the command times out
            printf 'wrangle: %s adapter timed out after %ds\n' "$tool" "$ADAPTER_TIMEOUT" >&2
            tool_status="error"
            overall_status=2
            ;;
        *)
            printf 'wrangle: %s adapter failed (exit %d)\n' "$tool" "$adapter_exit" >&2
            tool_status="error"
            overall_status=2
            ;;
    esac

    summary_tools+=("$tool")
    summary_statuses+=("$tool_status")
    printf '::endgroup::\n'
done

# Print summary table
printf '\nwrangle: === Summary ===\n'
printf 'wrangle: %-20s %s\n' "Tool" "Status"
printf 'wrangle: %-20s %s\n' "----" "------"
for i in "${!summary_tools[@]}"; do
    printf 'wrangle: %-20s %s\n' "${summary_tools[$i]}" "${summary_statuses[$i]}"
done

exit "$overall_status"
