#!/bin/bash
# lib/toolbox_run.sh — run wrangle's signing/verify toolbox (cosign, ampel, bnd,
# wrangle-attest) inside the curated attest-toolbox image. Sourced by
# actions/verify/run_verify.sh and lib/sign_metadata.sh.
#
# Provides:
#   wrangle_toolbox_image        — resolve, digest-pin-check, VSA-gate (memoized)
#   wrangle_toolbox_network      — the catalog network as a docker --network
#   wrangle_mint_sigstore_token  — mint aud=sigstore SIGSTORE_ID_TOKEN, step-local
#   wrangle_toolbox_exec         — one hardened docker run of the toolbox image

set -euo pipefail
set -f

_TOOLBOX_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/read_catalog.sh
source "$_TOOLBOX_RUN_DIR/read_catalog.sh"
# shellcheck source=lib/verify_image_vsa.sh
source "$_TOOLBOX_RUN_DIR/verify_image_vsa.sh"

WRANGLE_TOOLBOX_TOOL="attest-toolbox"

# The catalog the grant is read from; a test/adopter run may override it.
_wrangle_toolbox_catalog() {
    printf '%s\n' "${WRANGLE_CATALOG:-$_TOOLBOX_RUN_DIR/../tools/catalog.json}"
}

# Resolve the toolbox image, assert it is @sha256:-digest-pinned, and VSA-gate it
# before any container consumes it. Memoized so the network verify runs once per
# step. Echoes the image; returns 2 (no docker) on a missing/unpinned image or a
# non-PASSED VSA. WRANGLE_VERIFY_TOOL_IMAGES=0 skips the gate for a Sigstore outage.
_WRANGLE_TOOLBOX_IMAGE_VERIFIED=""
wrangle_toolbox_image() {
    if [[ -n "$_WRANGLE_TOOLBOX_IMAGE_VERIFIED" ]]; then
        printf '%s\n' "$_WRANGLE_TOOLBOX_IMAGE_VERIFIED"
        return 0
    fi
    local catalog image
    catalog="$(_wrangle_toolbox_catalog)"
    image="$(read_catalog_field "$catalog" "$WRANGLE_TOOLBOX_TOOL" image)"
    if [[ -z "$image" ]]; then
        printf 'wrangle: catalog %s has no %s image\n' "$catalog" "$WRANGLE_TOOLBOX_TOOL" >&2
        return 2
    fi
    if [[ ! "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
        printf 'wrangle: toolbox image must be @sha256:-digest-pinned (got %s)\n' "$image" >&2
        return 2
    fi
    if [[ "${WRANGLE_VERIFY_TOOL_IMAGES:-1}" == "0" ]]; then
        printf 'wrangle: toolbox-image VSA verification disabled by configuration\n' >&2
    elif verify_image_vsa "$image"; then
        printf 'wrangle: toolbox-image VSA verified PASSED\n' >&2
    else
        printf 'wrangle: toolbox-image VSA verification failed (image not provably PASSED)\n' >&2
        return 2
    fi
    _WRANGLE_TOOLBOX_IMAGE_VERIFIED="$image"
    printf '%s\n' "$image"
}

# "egress" -> docker's default bridge; anything else -> no network.
wrangle_toolbox_network() {
    case "$(read_catalog_field "$(_wrangle_toolbox_catalog)" "$WRANGLE_TOOLBOX_TOOL" network)" in
        egress) printf 'bridge\n' ;;
        *)      printf 'none\n' ;;
    esac
}

# Mint an aud=sigstore SIGSTORE_ID_TOKEN into this process's env only (never
# GITHUB_ENV, so it stays step-local); the in-container gitlab provider redeems it
# verbatim while the request-URL vars stay on the host. Idempotent within a step.
# Fails closed (2) if the catalog lacks the token: sigstore grant or the job lacks
# id-token: write — there is no in-job fallback.
wrangle_mint_sigstore_token() {
    [[ -n "${SIGSTORE_ID_TOKEN:-}" ]] && return 0
    if [[ "$(read_catalog_field "$(_wrangle_toolbox_catalog)" "$WRANGLE_TOOLBOX_TOOL" token)" != "sigstore" ]]; then
        printf 'wrangle: %s lacks the token: sigstore grant — cannot mint a signing token\n' "$WRANGLE_TOOLBOX_TOOL" >&2
        return 2
    fi
    local url="${ACTIONS_ID_TOKEN_REQUEST_URL:-}" reqtok="${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}"
    if [[ -z "$url" || -z "$reqtok" ]]; then
        printf 'wrangle: signing requires a Sigstore OIDC token but the job lacks id-token: write\n' >&2
        return 2
    fi
    # Bearer on stdin (-H @-), never argv, so it never lands on /proc/<pid>/cmdline.
    local resp token
    if ! resp="$(printf 'Authorization: bearer %s\n' "$reqtok" \
        | curl -sSf --retry 2 -H @- "${url}&audience=sigstore")"; then
        printf 'wrangle: failed to mint SIGSTORE_ID_TOKEN from the OIDC request endpoint\n' >&2
        return 1
    fi
    token="$(printf '%s' "$resp" | jq -r '.value // empty')"
    if [[ -z "$token" ]]; then
        printf 'wrangle: OIDC token endpoint returned no .value\n' >&2
        return 1
    fi
    export SIGSTORE_ID_TOKEN="$token"
}

# Append a bind mount (host path == container path) to the caller's mount-flags
# array, deduped by path. $1 = array name, $2 = path, $3 = ro|rw.
wrangle_toolbox_add_mount() {
    local -n _arr="$1"
    local path="$2" mode="$3" flag i
    for ((i = 0; i < ${#_arr[@]}; i++)); do
        [[ "${_arr[i]}" == "-v" && "${_arr[i + 1]%%:*}" == "$path" ]] && return 0
    done
    if [[ "$mode" == "ro" ]]; then flag="$path:$path:ro"; else flag="$path:$path"; fi
    _arr+=(-v "$flag")
}

# One hardened docker run of the VSA-gated toolbox image. The workspace ($PWD) and
# RUNNER_TEMP are bind-mounted at their own paths and the working dir is set to
# $PWD, so wrangle's relative METADATA_ROOT/SUBJECTS/command args resolve exactly
# as in-job (docker -v needs absolute paths; wrangle passes relative). Flags
# precede a `--`, then the in-container command:
#   --mount <dir>      extra read-only bind (e.g. the policy dir, outside $PWD)
#   --env <NAME>       thread host var NAME by name only, never its value on argv
#   --docker-config    mount the runner's registry credentials read-only
#   --                 end of flags
wrangle_toolbox_exec() {
    local -a mounts=() env_flags=(-e HOME=/tmp)
    local workdir="$PWD"
    wrangle_toolbox_add_mount mounts "$workdir" rw
    [[ -n "${RUNNER_TEMP:-}" && "$RUNNER_TEMP" != "$workdir" ]] &&
        wrangle_toolbox_add_mount mounts "$RUNNER_TEMP" rw
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --mount)        wrangle_toolbox_add_mount mounts "$2" ro; shift 2 ;;
            --env)          env_flags+=(-e "$2"); shift 2 ;;
            --docker-config)
                local cfg="${DOCKER_CONFIG:-$HOME/.docker}"
                mounts+=(-v "$cfg":/wrangle/docker-config:ro)
                env_flags+=(-e DOCKER_CONFIG=/wrangle/docker-config)
                shift ;;
            --)             shift; break ;;
            *)              printf 'wrangle_toolbox_exec: unexpected flag %s\n' "$1" >&2; return 2 ;;
        esac
    done
    local image net
    image="$(wrangle_toolbox_image)" || return 2
    net="$(wrangle_toolbox_network)"
    docker run --rm --network "$net" \
        --cap-drop ALL --security-opt no-new-privileges \
        -u "$(id -u):$(id -g)" -w "$workdir" \
        "${mounts[@]}" "${env_flags[@]}" \
        -- "$image" "$@"
}
