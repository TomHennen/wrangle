#!/bin/bash
# Validates inputs to the Go build action: shared path checks via
# lib/validate_path.sh, plus Go-specific checks that go.mod exists in the
# project directory and a goreleaser config is present.
#
# v0.1 requires .goreleaser.yml (or .goreleaser.yaml) — wrangle does not
# ship a starter goreleaser config; adopters BYO. See SPEC.md "Open
# questions" → ".goreleaser.yml template ownership."
#
# Usage: build/actions/go/validate_inputs.sh <path>

set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <path>\n' "$0" >&2
    exit 1
fi

INPUT_PATH="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/../../../lib/validate_path.sh" "$INPUT_PATH"

if [[ ! -f "$INPUT_PATH/go.mod" ]]; then
    printf 'Error: no go.mod found in %s\n' "$INPUT_PATH" >&2
    # shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
    printf 'Hint: run `go mod init <module>` in the project directory.\n' >&2
    exit 1
fi

# Goreleaser config detection — accept either common filename. Wrangle
# does not ship a starter; adopters must supply their own so the build
# attests what the adopter intended to release.
if [[ ! -f "$INPUT_PATH/.goreleaser.yml" ]] && [[ ! -f "$INPUT_PATH/.goreleaser.yaml" ]]; then
    printf 'Error: no .goreleaser.yml (or .goreleaser.yaml) found in %s\n' "$INPUT_PATH" >&2
    printf 'Hint: wrangle does not ship a starter goreleaser config; supply your own per https://goreleaser.com/customization/\n' >&2
    # shellcheck disable=SC2016 # backticks here are human-readable formatting, not command substitution
    printf '      The config MUST set `builds.flags: [-trimpath]` and `builds.env: [-buildvcs=false]` for reproducible builds.\n' >&2
    exit 1
fi
