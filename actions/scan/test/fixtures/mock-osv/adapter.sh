#!/bin/bash
set -euo pipefail

# Adapter contract: positional args are src_dir (read-only) and output_dir (writable).
# Mock doesn't scan src_dir but must accept both args.
_src_dir="$1"
output_dir="$2"

cat > "$output_dir/output.sarif" << 'SARIF'
{
  "version": "2.1.0",
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "runs": [{
    "tool": {"driver": {"name": "osv-scanner", "version": "1.0.0-mock"}},
    "results": []
  }]
}
SARIF
exit 0
