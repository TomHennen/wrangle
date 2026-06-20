#!/usr/bin/env bats

# Every composite/action manifest's header (the `name:` and `description:`
# fields, before inputs/outputs/runs) must contain no `${{ ... }}`
# expression. GitHub evaluates expressions in those manifest fields at load
# time, where step contexts like `github.action_path` are not defined — so a
# stray `${{ ... }}` there makes the whole action fail to load with
# "Unrecognized named-value", and only surfaces when the action is actually
# invoked (e.g. a dogfooded job), not in actionlint. This guards the header
# fields, where literal expressions are never legitimate.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "action manifests: no \${{ }} in the name/description header" {
    local bad=0
    while IFS= read -r -d '' manifest; do
        # Header = lines before the first of inputs:/outputs:/runs: (the
        # fields GitHub evaluates as literals at manifest load).
        header="$(awk '/^(inputs|outputs|runs):/ { exit } { print }' "$manifest")"
        if printf '%s\n' "$header" | grep -qF '${{'; then
            printf 'Expression in manifest header of %s:\n' "$manifest" >&2
            printf '%s\n' "$header" | grep -nF '${{' >&2
            bad=1
        fi
    done < <(find "$REPO_ROOT/actions" "$REPO_ROOT/build" "$REPO_ROOT/tools" \
        -name action.yml -type f -print0 2>/dev/null)
    [[ "$bad" -eq 0 ]]
}
