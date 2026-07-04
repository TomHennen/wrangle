#!/bin/bash
set -euo pipefail
set -f  # tools word-split into validated tokens; the orchestrator re-validates

# Run the adapter-pattern orchestrator (run.sh) and map its exit for the scan
# step: findings (run.sh exit 1) are gated by the later Check results step per
# each tool's :fail/:info policy, so they MUST NOT fail this step; only a tool
# error (exit 2+) does. run.sh keeps its own 0/1/2 contract for standalone use.
#
# Usage: run_scan.sh <src_dir> <output_dir> <tool[:policy]>...

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRANGLE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ $# -lt 3 ]]; then
    printf 'Usage: run_scan.sh <src_dir> <output_dir> <tool[:policy]>...\n' >&2
    exit 2
fi

src="$1"
out="$2"
shift 2

rc=0
"$WRANGLE_ROOT/run.sh" -s "$src" -o "$out" "$@" || rc=$?
if [[ "$rc" -ge 2 ]]; then
    exit "$rc"
fi
