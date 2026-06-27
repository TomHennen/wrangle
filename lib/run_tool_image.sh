#!/bin/bash
# lib/run_tool_image.sh — run a curated tool image under the contract sandbox.
# Sourced by run.sh (mirrors lib/verify_image_vsa.sh); uses read_catalog_field,
# which the caller is expected to have sourced.

set -euo pipefail
set -f

# run_tool_image <tool> <image> <output_dir> <src_dir> <catalog> <timeout> — run
# a digest-pinned image under the contract sandbox (read-only /src, writable
# /output owned by the runner UID, capabilities dropped, no new privileges).
# Network defaults closed; a declared secret (already name-validated by the
# caller) is forwarded into the container by name only. Returns the container's
# exit code under the 0/1/2 adapter contract.
run_tool_image() {
    local tool="$1" image="$2" tool_out="$3" src_dir="$4" catalog="$5" timeout_s="$6"
    local net secret secret_var extra_var src_abs out_abs

    # Network defaults closed; a tool grants egress only by declaring it.
    # "egress" maps to docker's default bridge network (full egress, the
    # access these tools already have today).
    net="none"
    [[ "$(read_catalog_field "$catalog" "$tool" network)" == "egress" ]] && net="bridge"

    # docker inherits no host env; a secret-declaring tool gets its
    # WRANGLE_EXTRA_<name> forwarded by name only, mirroring the adapter
    # path's WRANGLE_EXTRA_* forwarding. Default: no secrets.
    local -a docker_env=()
    secret="$(read_catalog_field "$catalog" "$tool" secret)"
    if [[ -n "$secret" ]]; then
        # Map a catalog secret name (e.g. github-token) to its env var
        # (WRANGLE_EXTRA_GITHUB_TOKEN). Export the value into run.sh's own
        # env and pass docker the name only, so the value never lands on
        # docker's argv (visible via ps/proc).
        secret_var="$(printf '%s' "$secret" | tr 'a-z-' 'A-Z_')"
        extra_var="WRANGLE_EXTRA_${secret_var}"
        if [[ -n "${!extra_var:-}" ]]; then
            export "${secret_var}=${!extra_var}"
            docker_env+=(-e "${secret_var}")
        fi
    fi

    # Absolute paths: docker -v needs them, and src_dir/output_dir may be
    # relative to cwd.
    src_abs="$(cd "$src_dir" && pwd)"
    out_abs="$(cd "$tool_out" && pwd)"

    local rc=0
    timeout "$timeout_s" docker run --rm --network "$net" \
        --cap-drop ALL --security-opt no-new-privileges \
        -u "$(id -u):$(id -g)" \
        -v "$src_abs":/src:ro -v "$out_abs":/output \
        "${docker_env[@]}" \
        -- "$image" /src /output || rc=$?
    return "$rc"
}
