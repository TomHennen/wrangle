#!/bin/bash
set -euo pipefail

# lib/env.sh — Set up wrangle environment paths.
#
# Source this script to get WRANGLE_BIN_DIR, WRANGLE_METADATA_DIR, and PATH
# configured. Safe to source multiple times (idempotent).
#
# Defaults use $RUNNER_TEMP and $GITHUB_WORKSPACE when available (CI),
# falling back to current-directory-relative paths for local use.

WRANGLE_BIN_DIR="${WRANGLE_BIN_DIR:-${RUNNER_TEMP:-.}/.wrangle/bin}"
WRANGLE_METADATA_DIR="${WRANGLE_METADATA_DIR:-${GITHUB_WORKSPACE:-.}/.wrangle/metadata}"
export WRANGLE_BIN_DIR WRANGLE_METADATA_DIR

# Add bin dir to PATH if not already present
case ":${PATH}:" in
    *":${WRANGLE_BIN_DIR}:"*) ;;
    *) export PATH="${WRANGLE_BIN_DIR}:${PATH}" ;;
esac
