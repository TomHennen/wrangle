#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external file contents

# lib/merge_catalog.sh — build the effective tool catalog by merging an adopter
# override file over wrangle's curated catalog (both share the
# { "tools": { … } } shape). An override entry's non-capability fields deep-merge
# over the curated entry; the capability grants network and secret hold ONLY when
# the override entry restates them, otherwise they reset closed — an override
# never inherits the replaced entry's network or secret.
#
# Usage: merge_catalog.sh <curated_catalog> <override_file>
# Prints the effective catalog on stdout. Exits non-zero (message on stderr) when
# the override is not valid JSON or any adopter entry fails validation.

merge_catalog() {
    local curated="$1" override="$2"
    local curated_json='{"tools":{}}'
    [[ -f "$curated" ]] && curated_json="$(cat "$curated")"

    if ! jq -e . "$override" >/dev/null 2>&1; then
        printf 'wrangle: tool-overrides is not valid JSON: %s\n' "$override" >&2
        return 1
    fi

    jq -n \
        --argjson curated "$curated_json" \
        --slurpfile ov "$override" '
        def digestpin: test("^[a-z0-9._-]+(:[0-9]+)?(/[a-z0-9._-]+)*@sha256:[0-9a-f]{64}$");
        def check($cond; $msg): if $cond then . else error($msg) end;

        ($ov[0]) as $o
        | ($curated.tools // {}) as $ct
        | check(($o | type) == "object"; "tool-overrides: top-level must be a JSON object")
        | check(($o | has("tools")) and (($o.tools | type) == "object");
                "tool-overrides: \"tools\" must be an object")
        | reduce ($o.tools | to_entries[]) as $e (0;
            ($e.key) as $t | ($e.value) as $v | ($ct | has($t)) as $known
            | (null
               | check(($t | test("^[a-z][a-z0-9_-]*$"));
                       "tool-overrides: invalid tool name: \($t)")
               | check(($v | type) == "object";
                       "tool-overrides: \($t): entry must be an object")
               | check(($v | has("kind") | not)
                       or (($v.kind | type) == "string" and ($v.kind | IN("scan","sbom","attest")));
                       "tool-overrides: \($t): kind must be one of scan, sbom, attest")
               | check(($v | has("network") | not) or ($v.network | IN("none","egress"));
                       "tool-overrides: \($t): network must be one of none, egress")
               | check(($v | has("secret") | not)
                       or (($v.secret | type) == "string" and ($v.secret | test("^[a-z][a-z0-9-]*$")));
                       "tool-overrides: \($t): secret must match ^[a-z][a-z0-9-]*$")
               | check(($v | has("image") | not) or ($v.image | digestpin);
                       "tool-overrides: \($t): image must be digest-pinned (name@sha256:<64hex>)")
               | check($known or ($v | has("image"));
                       "tool-overrides: \($t): a new tool must declare a digest-pinned image")
               | check($known or (($v.delivery // "") == "image");
                       "tool-overrides: \($t): a new tool must declare delivery: image"))
            | .)
        | { tools: ($ct + ($o.tools
                           | to_entries
                           | map({ key: .key, value: (($ct[.key] // {}) + .value) })
                           | from_entries)) }
        | .tools |= with_entries(
            (.key) as $t
            | if ($o.tools | has($t)) then
                .value |= ((if ($o.tools[$t] | has("network")) then . else del(.network) end)
                           | (if ($o.tools[$t] | has("secret")) then . else del(.secret) end))
              else . end)
    '
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -ne 2 ]]; then
        printf 'Usage: %s <curated_catalog> <override_file>\n' "${0##*/}" >&2
        exit 2
    fi
    merge_catalog "$1" "$2"
fi
