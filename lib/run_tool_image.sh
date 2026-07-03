#!/bin/bash
# lib/run_tool_image.sh — run a curated tool image under the contract sandbox.
# Sourced by run.sh; calls read_catalog_field (caller sources lib/read_catalog.sh).

set -euo pipefail
set -f

# run_tool_image <tool> <image> <output_dir> <src_dir> <catalog> <timeout>
# Returns the container's exit code under the 0/1/2 adapter contract.
run_tool_image() {
    local tool="$1" image="$2" tool_out="$3" src_dir="$4" catalog="$5" timeout_s="$6"
    local net kind secret secret_var extra_var src_abs out_abs

    # egress -> docker's default bridge network; absent -> none (closed).
    net="none"
    [[ "$(read_catalog_field "$catalog" "$tool" network)" == "egress" ]] && net="bridge"

    # docker -v needs absolute paths.
    src_abs="$(cd "$src_dir" && pwd)"
    out_abs="$(cd "$tool_out" && pwd)"

    # WRANGLE_KIND carries the tool's input/stage; WRANGLE_SOURCE_NAME the source
    # dir name, which the fixed /src mount otherwise hides.
    local -a docker_env=()
    kind="$(read_catalog_field "$catalog" "$tool" kind)"
    [[ -n "$kind" ]] && docker_env+=(-e "WRANGLE_KIND=$kind")
    docker_env+=(-e "WRANGLE_SOURCE_NAME=$(basename "$src_abs")")

    secret="$(read_catalog_field "$catalog" "$tool" secret)"
    if [[ -n "$secret" ]]; then
        # Pass the secret by name only, so its value never lands on docker's argv.
        secret_var="$(printf '%s' "$secret" | tr 'a-z-' 'A-Z_')"
        extra_var="WRANGLE_EXTRA_${secret_var}"
        if [[ -n "${!extra_var:-}" ]]; then
            export "${secret_var}=${!extra_var}"
            docker_env+=(-e "${secret_var}")
        fi
    fi

    local rc=0
    timeout "$timeout_s" docker run --rm --network "$net" \
        --cap-drop ALL --security-opt no-new-privileges \
        -u "$(id -u):$(id -g)" \
        -v "$src_abs":/src:ro -v "$out_abs":/output \
        "${docker_env[@]}" \
        -- "$image" /src /output || rc=$?
    return "$rc"
}
