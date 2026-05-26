#!/bin/bash
# Validates inputs to the Go checks composite: path + cache enum +
# govulncheck pinned-semver, plus go.mod presence in the project
# directory.
#
# Does NOT require `.goreleaser.yml` — the checks composite runs
# quality gates that are useful even on projects that haven't yet
# wired up goreleaser. The release composite's validate_inputs.sh
# enforces .goreleaser.yml presence at that side of the pipeline.
#
# Usage: build/actions/go/checks/validate_inputs.sh <path> <cache> <govulncheck-version>

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

if [[ $# -ne 3 ]]; then
    printf 'Usage: %s <path> <cache> <govulncheck-version>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
INPUT_CACHE="$2"
INPUT_GOVULN_VERSION="$3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$INPUT_CACHE" != "enabled" && "$INPUT_CACHE" != "disabled" ]]; then
    printf 'Error: cache input must be one of enabled|disabled (got: %s)\n' "$INPUT_CACHE" >&2
    exit 1
fi

# Govulncheck version must be a pinned semver tag. The value flows
# straight into `go install golang.org/x/vuln/cmd/govulncheck@<version>`
# in run_checks.sh — Go accepts `@latest`, `@main`, branch names, and
# pseudo-versions there, so wrangle MUST validate explicitly to enforce
# the supply-chain-discipline posture documented in CLAUDE.md.
#
# Allowed shape: vMAJOR.MINOR.PATCH with an optional `-<prerelease>` or
# `+<build>` suffix (semver 2.0.0). Examples: v1.1.4, v1.1.4-rc1,
# v2.0.0-beta.3, v1.0.0+go1.24.
#
# The composite's env wiring (`${{ inputs.govulncheck-version || 'v1.1.4' }}`)
# coalesces empty to the pin before we get here, so empty in practice
# only reaches this script if someone calls it directly. We still reject
# it with a clear message rather than silently re-defaulting — the env
# coalesce is the only place the default lives.
GOVULN_VERSION_REGEX='^v[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$'
if ! [[ "$INPUT_GOVULN_VERSION" =~ $GOVULN_VERSION_REGEX ]]; then
    printf 'Error: govulncheck-version %q is not a pinned semver tag (e.g. v1.1.4).\n' "$INPUT_GOVULN_VERSION" >&2
    printf 'Wrangle rejects @latest, @main, branch names, and other non-pinned refs — see CLAUDE.md "Supply Chain Discipline".\n' >&2
    exit 1
fi

"$SCRIPT_DIR/../../../../lib/validate_path.sh" "$INPUT_PATH"

if [[ ! -f "$INPUT_PATH/go.mod" ]]; then
    printf 'Error: no go.mod found in %s\n' "$INPUT_PATH" >&2
    # shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
    printf 'Hint: run `go mod init <module>` in the project directory.\n' >&2
    exit 1
fi
