#!/usr/bin/env bats

# tools/self_ref_pin_paths.sh is the single source of the directories that may
# hold wrangle self-reference pins. Its whole point is that bump_action_pins.sh
# (freshness) and check_pin_ancestry.sh (reachability) walk the *same* set — a
# nested pin one tool bumps but the other never validates is exactly the #381
# footgun. These tests fail closed if either consumer stops sourcing it or the
# set diverges, since a hardcoded copy in either script would silently re-open
# that gap.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    LIB="$REPO_ROOT/tools/self_ref_pin_paths.sh"
}

@test "self_ref_pin_paths: emits the expected non-empty path set" {
    # shellcheck source=../tools/self_ref_pin_paths.sh
    source "$LIB"
    mapfile -t paths < <(wrangle_self_ref_pin_paths)
    [ "${#paths[@]}" -gt 0 ]
    # Space-delimited containment, not `printf | grep -q`: grep exits on the match
    # while printf is still writing, and under pipefail that SIGPIPE is a 141.
    local want
    for want in '.github/workflows' 'actions' 'build' 'tools'; do
        [[ " ${paths[*]} " == *" $want "* ]]
    done
}

@test "self_ref_pin_paths: both pin tools source it rather than hardcoding paths" {
    grep -q 'source .*self_ref_pin_paths.sh' "$REPO_ROOT/tools/bump_action_pins.sh"
    grep -q 'source .*self_ref_pin_paths.sh' "$REPO_ROOT/tools/check_pin_ancestry.sh"
}
