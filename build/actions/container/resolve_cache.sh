#!/bin/bash
# Resolves the BuildKit GHA cache flags (cache-from / cache-to) for the
# container build, based on the adopter's cache policy and a per-PR scope.
#
# The four policies trade PR-build speed against PR-to-PR cache-poisoning
# exposure (see docs/SLSA_L3_AUDIT.md "Should wrangle care about PR-to-PR
# cache poisoning?"). Release builds never reach this script with anything
# but "disabled" — the reusable workflow forces that for SLSA L3.
#
#   enabled    cache-from + cache-to, shared cross-branch GHA scope.
#   read-only  cache-from only — PR builds consume the shared cache but
#              never write it, so a PR cannot poison entries.
#   isolated   cache-from + cache-to, namespaced by a per-PR scope — PR A
#              cannot write entries PR B reads.
#   disabled   no cache at all.
#
# Usage: build/actions/container/resolve_cache.sh <cache-mode> <scope>
#   cache-mode: enabled|disabled|isolated|read-only (validate_inputs.sh
#               has already constrained it to this allowlist)
#   scope:      raw branch/ref name; only consulted for "isolated"

set -euo pipefail
set -f  # disable globbing — processes externally-supplied arguments

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <cache-mode> <scope>\n' "$0" >&2
    exit 1
fi

mode="$1"
raw_scope="$2"

if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
    printf 'Error: resolve_cache.sh requires GITHUB_OUTPUT to be set\n' >&2
    exit 1
fi

# Sanitize the scope before it reaches the BuildKit cache config. The raw
# value is a branch/ref name — PR-author-controlled. It is interpolated
# into a comma-delimited `type=gha,scope=<value>` string, so an unsanitized
# value containing a comma (or `=`) could inject extra cache options (e.g.
# `,type=registry,ref=attacker/image`). Collapse to a conservative charset;
# LC_ALL=C keeps `tr` byte-wise so non-ASCII branch names can't slip a
# delimiter through a locale-specific class.
scope="$(printf '%s' "$raw_scope" | LC_ALL=C tr -c 'a-zA-Z0-9._-' '_')"
if [[ -z "$scope" ]]; then
    scope="default"
fi

case "$mode" in
    enabled)
        cache_from='type=gha'
        cache_to='type=gha,mode=max'
        ;;
    read-only)
        cache_from='type=gha'
        cache_to=''
        ;;
    isolated)
        cache_from="type=gha,scope=${scope}"
        cache_to="type=gha,mode=max,scope=${scope}"
        ;;
    disabled)
        cache_from=''
        cache_to=''
        ;;
    *)
        # validate_inputs.sh should have rejected this already; fail loudly
        # rather than silently emit an unintended (cache-on) configuration.
        printf 'Error: invalid cache mode: %s\n' "$mode" >&2
        exit 1
        ;;
esac

{
    printf 'cache-from=%s\n' "$cache_from"
    printf 'cache-to=%s\n' "$cache_to"
} >> "$GITHUB_OUTPUT"

printf 'Container cache policy: %s (cache-from=%q cache-to=%q)\n' \
    "$mode" "$cache_from" "$cache_to"
