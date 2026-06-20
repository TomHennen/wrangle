#!/bin/bash
# tools/gen_policies/gen.sh — generate the per-eco default/strict PolicySets
# from one template. The scan tenets (osv/zizmor/wrangle-lint) and the SLSA/SBOM
# tenet list live once in policy.hjson.in; strict appends scorecard-tenet.hjson.in.
# Ampel sources tenets only over http/git+, never a local path, so a single
# committed template + this generator is the only way to keep the eight files
# from drifting. CI regenerates and diffs (policies/test.bats).
#
# Usage: tools/gen_policies/gen.sh [output_dir]   (default: policies/)

set -euo pipefail
set -f

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="${1:-$REPO_ROOT/policies}"

TEMPLATE="$SCRIPT_DIR/policy.hjson.in"
SCORECARD="$SCRIPT_DIR/scorecard-tenet.hjson.in"

ECOS=(go npm python container)

# emit <tier> <eco>: substitute the eco/tier tokens, splice the scorecard tenet
# for strict, and write policies/wrangle-<tier>-<eco>-v1.hjson.
emit() {
    local tier="$1" eco="$2"
    local scorecard_tenet="" strict_doc="" strict_desc=""
    if [[ "$tier" == "strict" ]]; then
        scorecard_tenet="$(cat "$SCORECARD")"
        strict_doc=" It also requires an OpenSSF Scorecard aggregate score >= 7.0."
        strict_desc=" plus OpenSSF Scorecard >= 7.0"
    fi
    awk -v tier="$tier" -v eco="$eco" \
        -v scorecard="$scorecard_tenet" \
        -v strict_doc="$strict_doc" -v strict_desc="$strict_desc" '
        {
            gsub(/@TIER@/, tier)
            gsub(/@ECO@/, eco)
            gsub(/@STRICT_DOC@/, strict_doc)
            gsub(/@STRICT_DESC@/, strict_desc)
            gsub(/@SCORECARD_TENET@/, scorecard)
            print
        }
    ' "$TEMPLATE" > "$OUT_DIR/wrangle-$tier-$eco-v1.hjson"
}

for eco in "${ECOS[@]}"; do
    emit default "$eco"
    emit strict "$eco"
done

printf 'gen_policies: wrote %d default/strict PolicySet pair(s) to %s\n' \
    "${#ECOS[@]}" "$OUT_DIR"
