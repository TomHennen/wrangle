#!/bin/bash
# Validates inputs to the Go release composite: path, cache,
# install-zig, plus go.mod and .goreleaser.yml presence.
#
# Usage: build/actions/go/build/validate_inputs.sh <path> <cache> <install-zig>
#
#   path:        project directory (relative)
#   cache:       "enabled" or "disabled"
#   install-zig: "true" or "false"

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

if [[ $# -ne 3 ]]; then
    printf 'Usage: %s <path> <cache> <install-zig>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
INPUT_CACHE="$2"
INPUT_INSTALL_ZIG="$3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$INPUT_CACHE" != "enabled" && "$INPUT_CACHE" != "disabled" ]]; then
    printf 'Error: cache input must be one of enabled|disabled (got: %s)\n' "$INPUT_CACHE" >&2
    exit 1
fi

if [[ "$INPUT_INSTALL_ZIG" != "true" && "$INPUT_INSTALL_ZIG" != "false" ]]; then
    printf 'Error: install-zig input must be one of true|false (got: %s)\n' "$INPUT_INSTALL_ZIG" >&2
    exit 1
fi

"$SCRIPT_DIR/../../../../lib/validate_path.sh" "$INPUT_PATH"

if [[ ! -f "$INPUT_PATH/go.mod" ]]; then
    printf 'Error: no go.mod found in %s\n' "$INPUT_PATH" >&2
    # shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
    printf 'Hint: run `go mod init <module>` in the project directory.\n' >&2
    exit 1
fi

if [[ ! -f "$INPUT_PATH/.goreleaser.yml" ]] && [[ ! -f "$INPUT_PATH/.goreleaser.yaml" ]]; then
    printf 'Error: no .goreleaser.yml (or .goreleaser.yaml) found in %s\n' "$INPUT_PATH" >&2
    printf 'Hint: wrangle does not ship a starter goreleaser config; copy gh_workflow_examples/build_go.goreleaser.yml as a starting point.\n' >&2
    # shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
    printf '      The config MUST set `builds.flags: [-trimpath]` for reproducible builds.\n' >&2
    exit 1
fi
