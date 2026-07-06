#!/bin/bash
set -euo pipefail
set -f  # disable globbing — tool names come from external input

# Wrangle orchestrator — runs security tool images under the contract sandbox.
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

# Catalog reader: resolves a tool's curated entry (image, network, secret) from
# tools/catalog.json.
# shellcheck source=lib/read_catalog.sh
source "$SCRIPT_DIR/lib/read_catalog.sh"

# Shared catalog validation constants (tool-name, image-digest, namespace).
# shellcheck source=lib/catalog_rules.sh
source "$SCRIPT_DIR/lib/catalog_rules.sh"

# Catalog merger: merge_catalog builds the effective catalog when an adopter
# supplies a custom-tools file.
# shellcheck source=lib/merge_catalog.sh
source "$SCRIPT_DIR/lib/merge_catalog.sh"

# Pull-time VSA verification primitive: verify_image_vsa runs the fail-closed
# attestation gate the curated-image policy below applies.
# shellcheck source=lib/verify_image_vsa.sh
source "$SCRIPT_DIR/lib/verify_image_vsa.sh"

# Image-delivery runner: run_tool_image dispatches a curated image under the
# contract sandbox. Expects CATALOG, src_dir, and ADAPTER_TIMEOUT in scope.
# shellcheck source=lib/run_tool_image.sh
source "$SCRIPT_DIR/lib/run_tool_image.sh"
# shellcheck source=lib/write_tool_error_marker.sh
source "$SCRIPT_DIR/lib/write_tool_error_marker.sh"

TOOLS_DIR="${WRANGLE_TOOLS_DIR:-${SCRIPT_DIR}/tools}"
# The catalog lives beside the tools it describes, so a WRANGLE_TOOLS_DIR
# override (hermetic orchestrator tests) gets its own catalog.
CATALOG="${WRANGLE_CATALOG:-${TOOLS_DIR}/catalog.json}"

# Only wrangle-namespace images carry wrangle's VSA identity, so only these get
# the wrangle-signer attestation gate; an adopter custom-tool image (other
# namespace) is trusted under its own identity.
CURATED_IMAGE_PREFIX="$CATALOG_CURATED_IMAGE_PREFIX"

# Auto-discover a conventional .wrangle/tools.json at the workspace root and add
# its net-new tools to the catalog. Absent -> the curated catalog, unchanged. The
# resolved file must stay inside the workspace, so a symlink escaping it is
# rejected; the effective catalog is a temp file removed on exit.
custom_root="$(cd "${GITHUB_WORKSPACE:-$PWD}" 2>/dev/null && pwd -P)" || custom_root=""
custom_tools="${custom_root:+${custom_root}/.wrangle/tools.json}"
if [[ -n "$custom_tools" ]] && [[ -e "$custom_tools" ]]; then
    if ! custom_file="$(realpath -e -- "$custom_tools" 2>/dev/null)"; then
        printf 'wrangle: .wrangle/tools.json is unreadable: %s\n' "$custom_tools" >&2
        exit 2
    fi
    if [[ "$custom_file" != "$custom_root"/* ]]; then
        printf 'wrangle: .wrangle/tools.json resolves outside the workspace: %s\n' "$custom_file" >&2
        exit 2
    fi
    effective_catalog="$(mktemp "${TMPDIR:-/tmp}/wrangle-catalog-XXXXXX.json")"
    trap 'rm -f "$effective_catalog"' EXIT
    if ! merge_catalog "$CATALOG" "$custom_file" > "$effective_catalog"; then
        exit 2
    fi
    CATALOG="$effective_catalog"
fi

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

# Parse tool specs: strip :policy suffixes, collect the tools run by run.sh.
# run.sh dispatches only catalog image tools (via docker run). An action-pattern
# tool (has an action.yml) is invoked via its uses: step, so it is skipped here
# even when an adapter.sh is present only as its image entrypoint. Any other
# selected tool has no way to run and is rejected.
declare -a run_tools=()
for spec in "$@"; do
    tool="${spec%%:*}"
    if [[ ! "$tool" =~ $CATALOG_TOOL_NAME_RE ]]; then
        printf 'wrangle: invalid tool name: %s (must match %s)\n' "$tool" "$CATALOG_TOOL_NAME_RE" >&2
        exit 2
    fi
    # An action.yml means the tool runs via its uses: step, not run.sh.
    if [[ -d "${TOOLS_DIR}/${tool}" ]] && [[ -f "${TOOLS_DIR}/${tool}/action.yml" ]]; then
        continue
    fi
    # A curated image is the only path run.sh dispatches; a tool must name a
    # catalog image entry, else it is unknown/unrunnable.
    if [[ -z "$(read_catalog_field "$CATALOG" "$tool" image)" ]]; then
        printf 'wrangle: unknown tool: %s (no catalog image entry in %s)\n' "$tool" "$CATALOG" >&2
        exit 2
    fi
    run_tools+=("$tool")
done

if [[ ${#run_tools[@]} -eq 0 ]]; then
    printf 'wrangle: no tools to run\n'
    exit 0
fi

mkdir -p "$output_dir"

# Track overall status: 0=clean, 1=findings, 2=error
overall_status=0

# Adapter timeout (seconds) — bounds each tool image's run.
ADAPTER_TIMEOUT="${WRANGLE_ADAPTER_TIMEOUT:-600}"

# Summary tracking
declare -a summary_tools=()
declare -a summary_statuses=()

# verify_tool_image <tool> <image> — curated-image policy around the
# verify_image_vsa primitive. Fail closed: a wrangle-published image must carry a
# PASSED, SLSA-L3 wrangle VSA whose resourceUri is this image ref (matching
# policies/wrangle-vsa-consumer-v1.hjson) before it runs. Returns 0 to proceed, 1
# to refuse. Skips (returns 0) when verification is disabled or the image is not
# wrangle-published (an adopter override is trusted under a different identity).
verify_tool_image() {
    local tool="$1" image="$2"

    # Break-glass for a sustained Sigstore-TUF outage, which the gate hard-depends
    # on every run; not a routine off-switch.
    if [[ "${WRANGLE_VERIFY_TOOL_IMAGES:-1}" == "0" ]]; then
        printf 'wrangle: %s: tool-image VSA verification disabled by configuration\n' "$tool" >&2
        return 0
    fi

    if [[ "$image" != "${CURATED_IMAGE_PREFIX}"* ]]; then
        printf 'wrangle: %s: non-wrangle image, not wrangle-identity-verified: %s\n' "$tool" "$image" >&2
        return 0
    fi

    if verify_image_vsa "$image"; then
        printf 'wrangle: %s: tool-image VSA verified PASSED\n' "$tool" >&2
        return 0
    fi
    printf 'wrangle: %s: tool-image VSA verification failed (image not provably PASSED)\n' "$tool" >&2
    return 1
}

# fail_tool_config <tool> <output_dir> <marker_msg> — record an errored tool that
# returns early (catalog/config/install failure): set the fail-closed status,
# note it for the summary, write the ${output_dir}/error marker check_results
# reads, and close the log group. The marker lets the scan step run under
# continue-on-error while check_results owns the gate — so an :info tool's error
# stays informational, matching a :fail tool's error blocking. Caller returns.
fail_tool_config() {
    overall_status=2
    summary_tools+=("$1")
    summary_statuses+=("error")
    wrangle_write_tool_error_marker "$2" "$3"
    printf '::endgroup::\n'
}

# run_one_tool <tool> — run a single tool's pinned image under the contract
# sandbox, map its exit to the 0/1/2 contract, attest its recognized output
# files by name, and record the result. Updates overall_status and the summary
# arrays.
run_one_tool() {
    local tool="$1"
    printf '::group::wrangle/%s\n' "$tool"
    printf 'wrangle: === %s ===\n' "$tool"

    local tool_status="pass"
    local adapter_exit=0
    # tool_output_dir is ${output_dir}/${tool}/; the downstream collectors
    # consume ${metadata}/${tool}/output.sarif.
    local tool_output_dir="${output_dir}/${tool}"
    mkdir -p "$tool_output_dir"

    # Run the tool's pinned image under the contract sandbox (read-only /src,
    # writable /output owned by the runner UID). The image's entrypoint IS the
    # adapter, mapping the same 0/1/2 exit contract and writing its recognized
    # output files into /output.
    printf 'wrangle: running %s (image)...\n' "$tool"

    local image
    image="$(read_catalog_field "$CATALOG" "$tool" image)"
    if [[ -z "$image" ]]; then
        printf 'wrangle: %s: catalog entry names no image\n' "$tool" >&2
        fail_tool_config "$tool" "$tool_output_dir" "catalog entry names no image"
        return
    fi
    # Require an @sha256 digest pin (a tag alone is mutable); re-checked here
    # even though merge_catalog validated custom entries, as defense in depth.
    if [[ ! "$image" =~ $CATALOG_IMAGE_DIGEST_RE ]]; then
        printf 'wrangle: %s: image not digest-pinned: %s\n' "$tool" "$image" >&2
        fail_tool_config "$tool" "$tool_output_dir" "image not digest-pinned: $image"
        return
    fi
    # A declared secret name must be a valid env-var stem before it is mapped
    # into the container (config error, not a tool result).
    local secret
    secret="$(read_catalog_field "$CATALOG" "$tool" secret)"
    if [[ -n "$secret" ]] && [[ ! "$secret" =~ ^[a-z][a-z0-9-]*$ ]]; then
        printf 'wrangle: %s: invalid catalog secret name: %s\n' "$tool" "$secret" >&2
        fail_tool_config "$tool" "$tool_output_dir" "invalid catalog secret name: $secret"
        return
    fi

    # Fail closed: refuse to dispatch a curated image that cannot be proven to
    # carry a PASSED wrangle VSA.
    if ! verify_tool_image "$tool" "$image"; then
        fail_tool_config "$tool" "$tool_output_dir" "tool image VSA verification failed"
        return
    fi

    run_tool_image "$tool" "$image" "$tool_output_dir" \
        "$src_dir" "$CATALOG" "$ADAPTER_TIMEOUT" || adapter_exit=$?

    # Uniform 0/1/2 exit contract across kinds; a tool's kind selects its
    # input/stage, not this mapping.
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

    # Filename-driven attestation of the tool's primary output. Skip on error —
    # an attestation must claim a real result. A clean run that emits no
    # recognized file is a no-op (green, no artifact, no manifest).
    if [[ "$tool_status" != "error" ]]; then
        if [[ -f "${tool_output_dir}/output.sarif" ]]; then
            # Generate a human-readable summary if the adapter didn't.
            if [[ ! -s "${tool_output_dir}/output.md" ]] \
                && [[ ! -s "${tool_output_dir}/output.txt" ]]; then
                "$SCRIPT_DIR/lib/sarif_to_md.sh" "${tool_output_dir}/output.sarif" \
                    > "${tool_output_dir}/output.md" 2>/dev/null || true
            fi
            # Scan/v1 manifest, keyed per tool — the scanner name can differ from
            # the orchestrator token (osv -> osv-scanner).
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
        elif [[ -f "${tool_output_dir}/sbom.spdx.json" ]]; then
            # CycloneDX is future work: re-add it to this map alongside the
            # wrangle-attest engine allowlist + a test when a tool emits it.
            "$SCRIPT_DIR/lib/write_attest_manifest.sh" \
                "$tool_output_dir" "https://spdx.dev/Document" "sbom.spdx.json" \
                || printf 'wrangle: failed to write %s sbom manifest\n' "$tool" >&2
        fi
    else
        # An errored adapter run (timeout / nonzero exit): write the marker
        # check_results reads, so an :info tool's error stays informational and
        # the scan step can run under continue-on-error.
        wrangle_write_tool_error_marker "$tool_output_dir" "adapter error (exit ${adapter_exit})"
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
