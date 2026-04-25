#!/bin/bash
# lib/validate_path.sh — Shared path validation for wrangle build actions.
#
# Rejects absolute paths, parent-directory traversal, and any character
# outside [a-zA-Z0-9_./-]. The strict allowlist exists because the path
# flows into shell commands and filesystem operations downstream — see
# CLAUDE.md "Input Validation".
#
# Usage: lib/validate_path.sh <path>

set -euo pipefail
set -f  # disable globbing — processes external input

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <path>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"

if [[ "$INPUT_PATH" == /* ]]; then
    printf 'Error: path must be relative, got: %s\n' "$INPUT_PATH" >&2
    exit 1
fi
if [[ "$INPUT_PATH" == *..* ]]; then
    printf 'Error: path traversal not allowed: %s\n' "$INPUT_PATH" >&2
    exit 1
fi
if [[ ! "$INPUT_PATH" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
    printf 'Error: invalid characters in path: %s\n' "$INPUT_PATH" >&2
    exit 1
fi
