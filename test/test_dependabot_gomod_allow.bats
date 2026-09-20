#!/usr/bin/env bats

# Divergence guard between the `tool` directives in tools/go.mod and the gomod
# `allow` list in .github/dependabot.yml. Go records a tool module as
# `// indirect`, and version updates skip indirect modules unless an allow entry
# names them — so a tool added without its entry silently stops being bumped.
# Hermetic: `go mod edit -json` only reads the manifest.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    command -v go >/dev/null 2>&1 || { printf 'go not on PATH\n' >&2; return 1; }
    command -v jq >/dev/null 2>&1 || { printf 'jq not on PATH\n' >&2; return 1; }
}

# Third-party tool modules: each tool directive's package path resolved to the
# longest required module that is a prefix of it. Wrangle's own packages are
# dropped — they are the repo, not a dependency.
tool_modules() {
    go -C "$REPO_ROOT/tools" mod edit -json | jq -r '
        . as $doc
        | (($doc.Require // []) | map(.Path)) as $mods
        | ($doc.Tool // []) | map(.Path)
        | map(select(startswith("github.com/TomHennen/wrangle/") | not))
        | map(. as $tool
              | $mods
              | map(select(. as $mod | $tool == $mod or ($tool | startswith($mod + "/"))))
              | max_by(length))
        | map(select(. != null)) | unique | .[]' | LC_ALL=C sort -u
}

# dependency-name values inside the gomod entry's allow list (an ignore entry
# naming the same module must not read as coverage).
allowed_modules() {
    awk '/^  - package-ecosystem:/ { gomod = ($3 == "\"gomod\""); in_allow = 0 }
         /^    [a-z-]+:/           { in_allow = ($0 ~ /^    allow:/) }
         gomod && in_allow && /^ +- dependency-name:/ { gsub(/"/, "", $3); print $3 }' \
        "$REPO_ROOT/.github/dependabot.yml" | LC_ALL=C sort -u
}

@test "every tools/go.mod tool directive has a gomod dependency-name allow entry" {
    local tools missing
    tools="$(tool_modules)"
    [ -n "$tools" ]  # guard against the extraction silently matching nothing

    missing="$(comm -23 <(printf '%s\n' "$tools") <(allowed_modules))"
    if [ -n "$missing" ]; then
        printf 'tool modules with no dependabot allow entry:\n%s\n' "$missing" >&2
        return 1
    fi
}

@test "every gomod dependency-name allow entry is still a tool directive" {
    local stale
    stale="$(comm -13 <(tool_modules) <(allowed_modules))"
    if [ -n "$stale" ]; then
        printf 'dependabot allow entries naming no tool directive:\n%s\n' "$stale" >&2
        return 1
    fi
}
