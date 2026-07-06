#!/usr/bin/env bash
# Assemble tools/verify_documented_recipes.sh's flags from the action inputs
# (threaded in as env, never interpolated into this body) and run it.
#
# Env: FILE BUNDLE IMAGE DIGEST RESOURCE_URI REPO BUILD_TYPE (values), and
# PROVENANCE ATTESTATION_STORE NON_STRICT ("true" to enable).
set -euo pipefail
set -f

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${WRANGLE_RECIPE_RUNNER:-$SCRIPT_DIR/../../tools/verify_documented_recipes.sh}"

args=()
[[ -n "${FILE:-}" ]]         && args+=(--file "$FILE")
[[ -n "${BUNDLE:-}" ]]       && args+=(--bundle "$BUNDLE")
[[ -n "${IMAGE:-}" ]]        && args+=(--image "$IMAGE")
[[ -n "${DIGEST:-}" ]]       && args+=(--digest "$DIGEST")
[[ -n "${RESOURCE_URI:-}" ]] && args+=(--resource-uri "$RESOURCE_URI")
[[ -n "${REPO:-}" ]]         && args+=(--repo "$REPO")
[[ -n "${BUILD_TYPE:-}" ]]   && args+=(--type "$BUILD_TYPE")
[[ "${PROVENANCE:-}" == "true" ]]        && args+=(--provenance)
[[ "${ATTESTATION_STORE:-}" == "true" ]] && args+=(--attestation-store)
[[ "${NON_STRICT:-}" == "true" ]]        && args+=(--non-strict)

exec "$RUNNER" "${args[@]}"
