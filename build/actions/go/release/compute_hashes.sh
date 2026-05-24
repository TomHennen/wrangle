#!/bin/bash
# Computes the base64-encoded SHA-256 hashes for the SLSA generator's
# `base64-subjects` input from goreleaser's dist/checksums.txt.
#
# Goreleaser writes dist/checksums.txt in the standard `sha256sum`
# format — `<hex>  <filename>` per line — which is exactly what the
# generator expects when base64-encoded. So we just base64-encode
# the file directly (no re-hashing of the binaries).
#
# Why a separate script: the action.yml previously inlined this as
# `HASHES="$(base64 -w0 < "$INPUT_PATH/dist/checksums.txt")"`, which
# was untestable. Extracting it lets test.bats verify the output
# round-trips correctly against fixture checksums.txt files.
#
# Writes `hashes=<base64>` to $GITHUB_OUTPUT (a file the runner reads
# after the step). $GITHUB_OUTPUT writes are unaffected by the
# stop-commands suspension that may be in effect.
#
# Usage: build/actions/go/release/compute_hashes.sh <checksums_path>

set -euo pipefail
set -f  # processes external arguments — disable globbing per CLAUDE.md

# Pure function: base64-encode (no line wrap) the content of a file
# and print the result. Empty input prints an empty string. Stderr
# carries any read error.
#
# Args: <path>
encode_hashes() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        printf 'Error: checksums file not found: %s\n' "$path" >&2
        return 1
    fi
    base64 -w0 < "$path"
}

main() {
    if [[ $# -ne 1 ]]; then
        printf 'Usage: %s <checksums_path>\n' "$0" >&2
        exit 1
    fi

    local checksums="$1"
    local hashes
    hashes="$(encode_hashes "$checksums")"

    if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
        printf 'Error: GITHUB_OUTPUT not set; cannot emit hashes\n' >&2
        exit 1
    fi

    # File-based output (not the ::set-output:: stdout command), so
    # this write is unaffected by stop-commands suspension.
    printf 'hashes=%s\n' "$hashes" >> "$GITHUB_OUTPUT"
}

# Sourcing guard: tests source this file to call encode_hashes()
# directly without GITHUB_OUTPUT plumbing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
