#!/bin/bash
# Emit the per-build packaging artifact names for a build type to
# $GITHUB_OUTPUT, namespaced by the path-derived shortname so multiple
# builds in one workflow don't collide. Centralizes the name derivation
# the four reusable workflows shared, so they can't drift.
#
# Runs from the wrangle checkout (the composite's action_path), so it can
# source lib/shortname.sh — the build/release jobs that check out the
# ADOPTER repo can't, and must consume these outputs instead of deriving
# names themselves.
#
# Outputs (each suffix-less at the repo root): dist, scan, checks,
# metadata, metadata-pre, provenance-bundle, metadata-dir, and the
# resolved shortname.
#
# The shortname can be passed directly (the build job already has the build
# composite's output) or derived here from a path (the scan job, which runs
# before the build and only knows the input path). Either way derivation
# lands in one place — lib/shortname.sh — so the scan and build names agree.
#
# Usage: derive_names.sh <build-type> <shortname> [<path>]
#   <shortname> wins when non-empty; otherwise <path> is normalized via
#   derive_shortname (root '.' -> '').

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shortname.sh
source "$SCRIPT_DIR/../../lib/shortname.sh"

main() {
    if [[ $# -lt 2 || $# -gt 3 ]]; then
        printf 'Usage: %s <build-type> <shortname> [<path>]\n' "$0" >&2
        exit 1
    fi
    local type="$1" shortname="$2" path="${3:-}"

    # Scan-job mode: no shortname yet, derive it from the path so the scan
    # artifact name matches the build job's (which passes its shortname).
    if [[ -z "$shortname" && -n "$path" ]]; then
        shortname="$(derive_shortname "$path")"
    fi

    # derive_shortname maps path '/' -> '_' but keeps other path-legal
    # chars ('.', '-'), so 'python-uv' stays 'python-uv'. Re-assert that
    # shape (or empty at root) so a future caller can't smuggle a path
    # separator or shell metachar into a name.
    if [[ -n "$shortname" && ! "$shortname" =~ ^[A-Za-z0-9._-]+$ ]]; then
        printf 'Error: invalid shortname: %s\n' "$shortname" >&2
        exit 1
    fi
    if [[ ! "$type" =~ ^[a-z]+$ ]]; then
        printf 'Error: invalid build type: %s\n' "$type" >&2
        exit 1
    fi

    if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
        printf 'Error: GITHUB_OUTPUT not set; cannot emit names\n' >&2
        exit 1
    fi

    {
        printf 'dist=%s\n' "$(artifact_name "${type}-dist" "$shortname")"
        printf 'scan=%s\n' "$(artifact_name "${type}-scan" "$shortname")"
        printf 'checks=%s\n' "$(artifact_name "${type}-checks" "$shortname")"
        printf 'metadata=%s\n' "$(artifact_name "${type}-metadata" "$shortname")"
        printf 'metadata-pre=%s\n' "$(artifact_name "${type}-premeta" "$shortname")"
        printf 'provenance-bundle=%s\n' "$(artifact_name "${type}-provenance-bundle" "$shortname")"
        printf 'metadata-dir=%s\n' "$(metadata_dir "$type" "$shortname")"
        printf 'shortname=%s\n' "$shortname"
    } >> "$GITHUB_OUTPUT"
}

# Sourcing guard: tests source this file to call main() with a temp GITHUB_OUTPUT.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
