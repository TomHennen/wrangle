#!/bin/bash
set -euo pipefail
set -f

# tools/self_ref_pin_paths.sh — single source of the repo-relative directories
# that may hold wrangle self-reference action pins
# (uses: TomHennen/wrangle/...@<sha>).
#
# Both bump_action_pins.sh (freshness) and check_pin_ancestry.sh (reachability)
# walk this exact set, so a nested pin inside a composite — like actions/scan's
# tools/{zizmor,scorecard,dependency-review} refs — can't age or orphan unseen
# the way one would if the two tools disagreed on where to look.
#
# Usage: source this file, then collect the paths into an array.
#   source "$SCRIPT_DIR/self_ref_pin_paths.sh"
#   mapfile -t dirs < <(wrangle_self_ref_pin_paths)
# Callers resolve each entry against the git toplevel and skip any that are
# absent, so trees a given clone lacks are simply not searched.
#
# Callers match only YAML and skip fixtures/ subtrees: these trees hold lint
# test fixtures whose placeholder uses: lines would otherwise read as real
# pins. A checked-in fixture must therefore never carry a literal
# TomHennen/wrangle/...@<40-hex-sha> ref.
wrangle_self_ref_pin_paths() {
    printf '%s\n' \
        .github/workflows \
        actions \
        build \
        tools
}
