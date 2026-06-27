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

# Catalog reader: resolves a tool's curated entry (delivery, image, network,
# secret) from tools/catalog.json. A tool with no entry runs the adapter path.
# shellcheck source=lib/read_catalog.sh
source "$SCRIPT_DIR/lib/read_catalog.sh"

TOOLS_DIR="${WRANGLE_TOOLS_DIR:-${SCRIPT_DIR}/tools}"
# The catalog lives beside the tools it describes, so a WRANGLE_TOOLS_DIR
# override (hermetic orchestrator tests) gets its own catalog — or none, in
# which case every tool runs the adapter path.
CATALOG="${WRANGLE_CATALOG:-${TOOLS_DIR}/catalog.json}"

# Namespace prefix of wrangle-published tool images. Only these carry wrangle's
# VSA identity, so only these get the wrangle-signer attestation gate; an
# adopter-override image (other namespace) is trusted under its own identity.
CURATED_IMAGE_PREFIX="ghcr.io/tomhennen/wrangle/"

# is_image[$tool]=1 marks a catalog tool with delivery: image (the docker-run
# path); absence means the adapter path. Resolved once per tool in the parse
# loop so the go-install and dispatch loops branch on the same single answer.
declare -A is_image=()

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

# Parse tool specs: strip :policy suffixes, collect the tools run by run.sh —
# adapter-pattern tools (have an adapter.sh) plus catalog image-delivery tools
# (run via docker run). Action-pattern tools (have an action.yml) are invoked
# via their uses: step, so run.sh skips them even when an adapter.sh is present
# only as their image entrypoint. Unknown tools (no directory) are rejected.
TOOL_NAME_RE='^[a-z][a-z0-9_-]*$'
declare -a run_tools=()
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
    # An action.yml means the tool runs via its uses: step; skip it here even if
    # an adapter.sh exists (it is only the tool image's contract entrypoint).
    if [[ -f "${TOOLS_DIR}/${tool}/action.yml" ]]; then
        continue
    fi
    # Resolve delivery once. Empty -> adapter path; "image" -> docker path; any
    # other non-empty value is a catalog typo, not a silent adapter fallthrough.
    delivery="$(read_catalog_field "$CATALOG" "$tool" delivery)"
    case "$delivery" in
        image) is_image[$tool]=1 ;;
        ''|adapter) ;;
        *)
            printf 'wrangle: %s: unrecognized catalog delivery: %s\n' "$tool" "$delivery" >&2
            exit 2 ;;
    esac
    if [[ -n "${is_image[$tool]:-}" ]] || [[ -f "${TOOLS_DIR}/${tool}/adapter.sh" ]]; then
        run_tools+=("$tool")
    fi
done

if [[ ${#run_tools[@]} -eq 0 ]]; then
    printf 'wrangle: no adapter-pattern tools to run\n'
    exit 0
fi

mkdir -p "$output_dir"

# Track overall status: 0=clean, 1=findings, 2=error
overall_status=0

# Timeout defaults (seconds)
INSTALL_TIMEOUT="${WRANGLE_INSTALL_TIMEOUT:-300}"
ADAPTER_TIMEOUT="${WRANGLE_ADAPTER_TIMEOUT:-600}"
VERIFY_TIMEOUT="${WRANGLE_VERIFY_TIMEOUT:-120}"

# Build only the Go tools the requested adapters need: each adapter lists its
# package(s) in tools/<tool>/go-tools, version-pinned in tools/go.mod (env.sh
# pins GOPROXY/GOSUMDB; Dependabot keeps them fresh). A scan thus never compiles
# the build/verify toolchain (cosign, ampel, bnd). Empty when no requested
# adapter declares a Go tool (hermetic orchestrator tests point WRANGLE_TOOLS_DIR
# at stub dirs with no go-tools file). Retried: go does not retry transient
# proxy failures itself.
declare -a go_pkgs=()
for tool in "${run_tools[@]}"; do
    # Image-delivery tools ship prebuilt in their image — never go-install them.
    [[ -n "${is_image[$tool]:-}" ]] && continue
    go_tools_file="${TOOLS_DIR}/${tool}/go-tools"
    [[ -f "$go_tools_file" ]] || continue
    while IFS= read -r pkg || [[ -n "$pkg" ]]; do
        [[ -z "$pkg" ]] && continue
        go_pkgs+=("$pkg")
    done < "$go_tools_file"
done

if [[ ${#go_pkgs[@]} -gt 0 ]]; then
    if ! command -v go >/dev/null 2>&1; then
        printf 'wrangle: go not on PATH (required for tools/go.mod tools)\n' >&2
        exit 2
    fi
    mkdir -p "$WRANGLE_BIN_DIR"
    printf 'wrangle: installing Go tools: %s\n' "${go_pkgs[*]}"
    go_tools_exit=1
    backoff=1
    for attempt in 1 2 3; do
        go_tools_exit=0
        timeout "$INSTALL_TIMEOUT" env GOBIN="$(cd "$WRANGLE_BIN_DIR" && pwd)" \
            go -C "$TOOLS_DIR" install "${go_pkgs[@]}" || go_tools_exit=$?
        [[ "$go_tools_exit" -eq 0 ]] && break
        if [[ "$attempt" -lt 3 ]]; then
            printf 'wrangle: go install attempt %d/3 failed, retrying in %ds...\n' "$attempt" "$backoff" >&2
            sleep "$backoff"
            backoff=$((backoff * 2))
        fi
    done
    if [[ "$go_tools_exit" -ne 0 ]]; then
        printf 'wrangle: FATAL: installing Go tools failed\n' >&2
        exit 2
    fi
fi

# Summary tracking
declare -a summary_tools=()
declare -a summary_statuses=()

# run_tool_image <tool> <image> <output_dir> — run a digest-pinned image under
# the contract sandbox (read-only /src, writable /output owned by the runner
# UID, capabilities dropped, no new privileges). Network defaults closed; a
# declared secret (already name-validated by the caller) is forwarded into the
# container by name only. Returns the container's exit code under the 0/1/2
# adapter contract.
run_tool_image() {
    local tool="$1" image="$2" tool_out="$3"
    local net secret secret_var extra_var src_abs out_abs

    # Network defaults closed; a tool grants egress only by declaring it.
    # "egress" maps to docker's default bridge network (full egress, the
    # access these tools already have today).
    net="none"
    [[ "$(read_catalog_field "$CATALOG" "$tool" network)" == "egress" ]] && net="bridge"

    # docker inherits no host env; a secret-declaring tool gets its
    # WRANGLE_EXTRA_<name> forwarded by name only, mirroring the adapter
    # path's WRANGLE_EXTRA_* forwarding. Default: no secrets.
    local -a docker_env=()
    secret="$(read_catalog_field "$CATALOG" "$tool" secret)"
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
    timeout "$ADAPTER_TIMEOUT" docker run --rm --network "$net" \
        --cap-drop ALL --security-opt no-new-privileges \
        -u "$(id -u):$(id -g)" \
        -v "$src_abs":/src:ro -v "$out_abs":/output \
        "${docker_env[@]}" \
        -- "$image" /src /output || rc=$?
    return "$rc"
}

# verify_tool_image <tool> <image> — fail-closed pull-time VSA gate. A curated
# wrangle image MUST carry a PASSED verification-summary attestation signed by
# wrangle's container build+publish workflow before it runs. Returns 0 to
# proceed, non-zero to refuse. gh attestation verify checks signature, identity,
# and digest but never the predicate verdict — the jq is the ONLY check that the
# verdict is PASSED; dropping it makes the gate theater. Output is a JSON array,
# asserted array-safely (empty array fails). Skips (returns 0) when disabled or
# when the image is not wrangle-published.
verify_tool_image() {
    local tool="$1" image="$2"

    if [[ "${WRANGLE_VERIFY_TOOL_IMAGES:-1}" == "0" ]]; then
        printf 'wrangle: %s: tool-image VSA verification disabled by configuration\n' "$tool" >&2
        return 0
    fi

    if [[ "$image" != "${CURATED_IMAGE_PREFIX}"* ]]; then
        printf 'wrangle: %s: non-wrangle image, not wrangle-identity-verified: %s\n' "$tool" "$image" >&2
        return 0
    fi

    if ! command -v gh >/dev/null 2>&1; then
        printf 'wrangle: %s: gh not found; cannot verify tool image attestation\n' "$tool" >&2
        return 1
    fi

    local rc=0
    timeout "$VERIFY_TIMEOUT" gh attestation verify "oci://${image}" \
        --repo TomHennen/wrangle \
        --bundle-from-oci \
        --signer-workflow TomHennen/wrangle/.github/workflows/build_and_publish_container.yml \
        --predicate-type https://slsa.dev/verification_summary/v1 \
        --format json \
        | jq -e 'length>0 and all(.[]; .verificationResult.statement.predicate.verificationResult=="PASSED")' >/dev/null \
        || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'wrangle: %s: tool-image VSA verification failed (image not provably PASSED)\n' "$tool" >&2
        return 1
    fi
    printf 'wrangle: %s: tool-image VSA verified PASSED\n' "$tool"
    return 0
}

# run_one_tool <tool> — run a single tool through its delivery path (image via
# docker, otherwise the in-process adapter), map its exit to the 0/1/2 contract,
# generate human-readable output and the scan manifest, and record the result.
# Updates overall_status and the summary arrays.
run_one_tool() {
    local tool="$1"
    printf '::group::wrangle/%s\n' "$tool"
    printf 'wrangle: === %s ===\n' "$tool"

    local tool_status="pass"
    local adapter_exit=0
    # tool_output_dir is the SAME ${output_dir}/${tool}/ both paths write to —
    # the downstream collectors consume ${metadata}/${tool}/output.sarif.
    local tool_output_dir="${output_dir}/${tool}"
    mkdir -p "$tool_output_dir"

    if [[ -n "${is_image[$tool]:-}" ]]; then
        # Image-delivery: run the tool's pinned image under the contract
        # sandbox (read-only /src, writable /output owned by the runner UID).
        # The image's entrypoint IS the adapter, so it maps the same 0/1/2
        # exit contract and writes output.sarif (+ output.md) into /output.
        printf 'wrangle: running %s (image)...\n' "$tool"

        local image
        image="$(read_catalog_field "$CATALOG" "$tool" image)"
        if [[ -z "$image" ]]; then
            printf 'wrangle: %s: catalog declares delivery: image but no image\n' "$tool" >&2
            tool_status="error"
            overall_status=2
            summary_tools+=("$tool")
            summary_statuses+=("$tool_status")
            printf '::endgroup::\n'
            return
        fi
        # Require an @sha256 digest pin (a tag alone is mutable); the registry
        # host may carry a :port (e.g. registry.internal:5000/osv@sha256:...).
        if [[ ! "$image" =~ ^[a-z0-9._-]+(:[0-9]+)?(/[a-z0-9._-]+)*@sha256:[0-9a-f]{64}$ ]]; then
            printf 'wrangle: %s: image not digest-pinned: %s\n' "$tool" "$image" >&2
            tool_status="error"
            overall_status=2
            summary_tools+=("$tool")
            summary_statuses+=("$tool_status")
            printf '::endgroup::\n'
            return
        fi
        # A declared secret name must be a valid env-var stem before it is
        # mapped into the container (config error, not a tool result).
        local secret
        secret="$(read_catalog_field "$CATALOG" "$tool" secret)"
        if [[ -n "$secret" ]] && [[ ! "$secret" =~ ^[a-z][a-z0-9-]*$ ]]; then
            printf 'wrangle: %s: invalid catalog secret name: %s\n' "$tool" "$secret" >&2
            tool_status="error"
            overall_status=2
            summary_tools+=("$tool")
            summary_statuses+=("$tool_status")
            printf '::endgroup::\n'
            return
        fi

        # Fail closed: refuse to dispatch a curated image that cannot be proven
        # to carry a PASSED wrangle VSA.
        if ! verify_tool_image "$tool" "$image"; then
            tool_status="error"
            overall_status=2
            summary_tools+=("$tool")
            summary_statuses+=("$tool_status")
            printf '::endgroup::\n'
            return
        fi

        run_tool_image "$tool" "$image" "$tool_output_dir" || adapter_exit=$?
    else
        # Adapter-pattern (in-process) path.

        # Step 1: Install — only tools with a bespoke install.sh (the escape
        # hatch for tools no package manager ships); go.mod tools were all
        # installed upfront.
        local install_exit=0
        if [[ -f "${TOOLS_DIR}/${tool}/install.sh" ]]; then
            printf 'wrangle: installing %s...\n' "$tool"
            timeout "$INSTALL_TIMEOUT" "${TOOLS_DIR}/${tool}/install.sh" || install_exit=$?
        fi

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
            printf '::endgroup::\n'
            return
        fi

        # Step 2: Snapshot workspace for post-execution filesystem check
        # Records file paths, sizes, and mtimes to detect additions, removals, and modifications
        local pre_snapshot post_snapshot
        pre_snapshot="$(mktemp "${TMPDIR:-/tmp}/wrangle-pre-XXXXX")"
        # Exclude output_dir from snapshot — when metadata dir is inside src_dir
        # (workspace-relative), adapter writes there are expected, not rogue.
        find "$src_dir" -not -path "${output_dir}/*" -type f -printf '%p %s %T@\n' 2>/dev/null | sort > "$pre_snapshot" || true

        # Step 3: Run adapter with isolated environment
        printf 'wrangle: running %s...\n' "$tool"

        # Build restricted environment: only allowlisted variables + WRANGLE_EXTRA_*
        local -a adapter_env=(
            "PATH=${PATH}"
            "HOME=${HOME:-}"
            "TMPDIR=${TMPDIR:-/tmp}"
            "RUNNER_TEMP=${RUNNER_TEMP:-}"
            "GITHUB_WORKSPACE=${GITHUB_WORKSPACE:-}"
            "GITHUB_STEP_SUMMARY=${GITHUB_STEP_SUMMARY:-}"
        )
        # Forward WRANGLE_EXTRA_* variables with prefix stripped
        local key value stripped_key
        while IFS='=' read -r key value; do
            if [[ "$key" == WRANGLE_EXTRA_* ]]; then
                stripped_key="${key#WRANGLE_EXTRA_}"
                adapter_env+=("${stripped_key}=${value}")
            fi
        done < <(env)

        timeout "$ADAPTER_TIMEOUT" env -i "${adapter_env[@]}" \
            "${TOOLS_DIR}/${tool}/adapter.sh" "$src_dir" "$tool_output_dir" || adapter_exit=$?

        # Step 4: Post-execution filesystem check
        post_snapshot="$(mktemp "${TMPDIR:-/tmp}/wrangle-post-XXXXX")"
        find "$src_dir" -not -path "${output_dir}/*" -type f -printf '%p %s %T@\n' 2>/dev/null | sort > "$post_snapshot" || true
        if ! diff -q "$pre_snapshot" "$post_snapshot" >/dev/null 2>&1; then
            printf 'wrangle: WARNING: %s modified files outside its output directory\n' "$tool" >&2
        fi
        rm -f "$pre_snapshot" "$post_snapshot"
    fi

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

    # Generate human-readable output if the adapter didn't produce one.
    # Only on successful runs — on error the SARIF may be missing or
    # incomplete, and showing "No findings" would be misleading.
    if [[ "$tool_status" != "error" ]] \
        && [[ -f "${tool_output_dir}/output.sarif" ]] \
        && [[ ! -s "${tool_output_dir}/output.md" ]] \
        && [[ ! -s "${tool_output_dir}/output.txt" ]]; then
        "$SCRIPT_DIR/lib/sarif_to_md.sh" "${tool_output_dir}/output.sarif" \
            > "${tool_output_dir}/output.md" 2>/dev/null || true
    fi

    # Write the scan/v1 attestation manifest next to output.sarif so the
    # trusted verify job's wrangle-attest engine wraps + signs it. Skip on
    # error (an attestation must claim a real scan result); write_scan_manifest
    # itself no-ops on a missing SARIF. The scanner name can differ from the
    # orchestrator token (osv -> osv-scanner); keyed per tool, one line each.
    if [[ "$tool_status" != "error" ]]; then
        local scanner_name=""
        case "$tool" in
            osv) scanner_name="osv-scanner" ;;
            wrangle-lint) scanner_name="wrangle-lint" ;;
            zizmor) scanner_name="zizmor" ;;
        esac
        if [[ -n "$scanner_name" ]]; then
            "$SCRIPT_DIR/lib/write_scan_manifest.sh" "$scanner_name" \
                "${tool_output_dir}/output.sarif" \
                || printf 'wrangle: failed to write %s scan manifest\n' "$tool" >&2
        fi
    fi

    summary_tools+=("$tool")
    summary_statuses+=("$tool_status")
    printf '::endgroup::\n'
}

for tool in "${run_tools[@]}"; do
    run_one_tool "$tool"
done

# Print summary table
printf '\nwrangle: === Summary ===\n'
printf 'wrangle: %-20s %s\n' "Tool" "Status"
printf 'wrangle: %-20s %s\n' "----" "------"
for i in "${!summary_tools[@]}"; do
    printf 'wrangle: %-20s %s\n' "${summary_tools[$i]}" "${summary_statuses[$i]}"
done

exit "$overall_status"
