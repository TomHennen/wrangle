#!/usr/bin/env bats

# Divergence guard for the per-adapter Go package list. Each adapter names the
# package(s) it needs in tools/<tool>/go-tools; run.sh installs exactly those,
# at the version pinned by tools/go.mod's `tool` block. The package path thus
# lives in two files, so this fails closed when a go-tools entry is not a pinned
# tool directive — otherwise run.sh would try to install an unpinned package.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO_ROOT
}

@test "every tools/*/go-tools package is a pinned tool directive in tools/go.mod" {
    cd "$REPO_ROOT"

    local tool_pkgs
    tool_pkgs="$(awk '
        /^tool[[:space:]]*\(/ {inblock=1; next}
        inblock && /^\)/      {inblock=0; next}
        inblock               {gsub(/[[:space:]]/,""); if ($0!="") print; next}
        /^tool[[:space:]]+[^(]/ {print $2}
    ' tools/go.mod)"
    [ -n "$tool_pkgs" ]  # guard against the extraction silently matching nothing

    local saw_any=0 gt pkg
    while IFS= read -r gt; do
        while IFS= read -r pkg || [ -n "$pkg" ]; do
            [ -z "$pkg" ] && continue
            saw_any=1
            if ! printf '%s\n' "$tool_pkgs" | grep -Fxq "$pkg"; then
                printf 'go-tools drift: %s (in %s) is not a tool directive in tools/go.mod\n' \
                    "$pkg" "$gt" >&2
                return 1
            fi
        done < "$gt"
    done < <(find tools -mindepth 2 -maxdepth 2 -name go-tools | sort)

    [ "$saw_any" -eq 1 ]  # at least one adapter must declare a Go tool
}
