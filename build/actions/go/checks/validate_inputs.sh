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

# Semver 2.0.0 + Go pseudo-version shape (vX.Y.Z with optional
# `-<prerelease>` and/or `+<build>` suffix). See build/actions/go/SPEC.md
# "govulncheck-version policy" for the rationale (`go install` accepts
# floating refs; wrangle enforces pinned-only).
GOVULN_VERSION_REGEX='^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?(\+[A-Za-z0-9.-]+)?$'
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
