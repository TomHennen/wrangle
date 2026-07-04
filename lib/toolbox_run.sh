#!/bin/bash
# lib/toolbox_run.sh — shared primitives for running wrangle's signing/verify
# toolbox (cosign, ampel, bnd, wrangle-attest) inside the curated attest-toolbox
# image. Sourced by actions/verify/run_verify.sh and lib/sign_metadata.sh; each
# signer helper containerizes only when the grant + opt-in are present, and runs
# the in-job binary byte-for-byte otherwise (the break-glass revert).
#
# Provides:
#   wrangle_toolbox_optin            — the WRANGLE_VERIFY_AMPEL_TOOLBOX toggle
#   wrangle_toolbox_signing_enabled  — optin AND the catalog token: sigstore grant
#   wrangle_toolbox_image            — resolve, digest-pin-check, VSA-gate (memoized)
#   wrangle_toolbox_network          — the catalog network as a docker --network
#   wrangle_mint_sigstore_token      — mint aud=sigstore SIGSTORE_ID_TOKEN, step-local
#   wrangle_toolbox_exec             — one hardened docker run of the toolbox image

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

# True when the opt-in toggle selects the toolbox image over the in-job binary.
wrangle_toolbox_optin() {
    case "${WRANGLE_VERIFY_AMPEL_TOOLBOX:-}" in
        1|true) return 0 ;;
        *)      return 1 ;;
    esac
}

# True when signing may run in-container: the opt-in AND the catalog's
# attest-toolbox carrying the token: sigstore grant. Absent grant keeps signing
# in-job even under the opt-in, so a container never signs without a declared
# token grant.
wrangle_toolbox_signing_enabled() {
    wrangle_toolbox_optin || return 1
    [[ "$(read_catalog_field "$(_wrangle_toolbox_catalog)" "$WRANGLE_TOOLBOX_TOOL" token)" == "sigstore" ]]
}

# Resolve the toolbox image, assert it is @sha256:-digest-pinned, and VSA-gate it
# fail-closed before any container consumes it. Memoized: the digest is immutable
# within a step, so the gate's network verify runs once and every later docker run
# reuses the verdict. Echoes the image on success; returns 2 (no docker) on a
# missing/unpinned image or a non-PASSED VSA. WRANGLE_VERIFY_TOOL_IMAGES=0 is the
# sustained-Sigstore-outage break-glass that skips the gate.
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

# Mint an aud=sigstore SIGSTORE_ID_TOKEN from the ambient GitHub OIDC request vars
# into this process's env only — never GITHUB_ENV, so it stays step-local. The
# in-container gitlab provider of carabiner-dev/signer redeems it verbatim; the
# request-URL vars stay on the host, so the container cannot mint a token for any
# other audience. Idempotent within a step. Returns 2 when the request vars are
# absent (the job lacks id-token: write).
wrangle_mint_sigstore_token() {
    [[ -n "${SIGSTORE_ID_TOKEN:-}" ]] && return 0
    local url="${ACTIONS_ID_TOKEN_REQUEST_URL:-}" reqtok="${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}"
    if [[ -z "$url" || -z "$reqtok" ]]; then
        printf 'wrangle: cannot mint SIGSTORE_ID_TOKEN — ambient OIDC request vars absent (job needs id-token: write)\n' >&2
        return 2
    fi
    local resp token
    if ! resp="$(curl -sSf --retry 2 -H "Authorization: bearer $reqtok" "${url}&audience=sigstore")"; then
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

# Append a bind mount (host path == container path, so the in-container command
# reads the same absolute paths the in-job binary would) to the caller's mount-
# flags array, deduped by path. $1 = array name, $2 = path, $3 = ro|rw.
wrangle_toolbox_add_mount() {
    local -n _arr="$1"
    local path="$2" mode="$3" flag i
    for ((i = 0; i < ${#_arr[@]}; i++)); do
        [[ "${_arr[i]}" == "-v" && "${_arr[i + 1]%%:*}" == "$path" ]] && return 0
    done
    if [[ "$mode" == "ro" ]]; then flag="$path:$path:ro"; else flag="$path:$path"; fi
    _arr+=(-v "$flag")
}

# One hardened docker run of the VSA-gated toolbox image. Flags precede a `--`
# separator, then the in-container command:
#   -v <spec>          add a bind mount (repeatable)
#   --env <NAME>       thread the host env var NAME by name only, never by value
#                      (its value never lands on docker's argv)
#   --docker-config    mount the runner's registry credentials read-only so
#                      cosign/ampel reach ghcr with the job's login
#   --                 end of flags; the rest is the command run in the image
# The token-minting request vars are never threaded; callers pass only
# SIGSTORE_ID_TOKEN and/or GITHUB_TOKEN via --env. No retry/capture here — callers
# wrap this in wrangle_retry_once exactly where they wrap the in-job binary.
wrangle_toolbox_exec() {
    local -a mounts=() env_flags=(-e HOME=/tmp)
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -v)             mounts+=(-v "$2"); shift 2 ;;
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
        -u "$(id -u):$(id -g)" \
        "${mounts[@]}" "${env_flags[@]}" \
        "$image" "$@"
}
