#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles external tool names

# tools/check_catalog_freshness.sh — adoption-lag freshness check for the curated
# image entries in tools/catalog.json. For each curated `delivery: image` entry on
# the registry namespace ghcr.io/tomhennen/wrangle/*, it resolves the registry
# digest of the tool's moving `:latest` tag and compares it to the catalog's
# pinned @sha256: digest. A mismatch means wrangle published a newer tool image
# but the catalog still points at the old one (the #264/#539 stale-but-green hole).
#
# BOUNDARY — what this proves and what it does NOT:
#   It proves only ADOPTION LAG: the catalog has not picked up a newer published
#   image. It does NOT prove the pinned digest was built from current tool source
#   (the stronger §11 provenance guarantee — image SLSA provenance → source commit
#   → diff against HEAD — is a separate, deferred check). Two consequences:
#     - False positive: a cold-cache rebuild can repoint :latest to a new digest
#       with unchanged source (container builds aren't bit-reproducible); the
#       remediation (a digest bump) is harmless then.
#     - False negative: a source change that doesn't republish the image leaves
#       :latest unchanged. The publish trigger covers tools/** and lib/**, so the
#       window is small but real.
#
# Digest resolution is an anonymous GHCR registry-API call over curl (the curated
# images are public); the index media types in Accept return the same multi-arch
# index digest the catalog pins.
#
# Coupling: this is only meaningful because build/actions/container/action.yml
# pushes the `:latest` tag on main; if that tag stops being published, every
# curated entry resolves a backend error (exit 2), not a false in-sync.
#
# Catalog path: $WRANGLE_CATALOG, else the catalog beside this script.
#
# Exit: 0 all in sync, 1 a digest drifted (bump remediation printed),
#       2 the registry was unreachable or a backend failed (NOT a false failure).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/read_catalog.sh
source "$SCRIPT_DIR/../lib/read_catalog.sh"

# Tool segment matches run.sh's tool-name shape, so a crafted `..` segment can't
# turn curl's path into a cross-repo query.
CURATED_PREFIX_RE='^ghcr\.io/tomhennen/wrangle/[a-z][a-z0-9_-]*$'
DIGEST_RE='^sha256:[0-9a-f]{64}$'

# resolve_latest_digest <imagename> — anonymous GHCR digest of <imagename>:latest
# via the registry API. Prints the index digest on success; non-zero on any
# backend failure (token fetch, registry read, or a missing/malformed digest).
resolve_latest_digest() {
    local imagename="$1" registry repo token digest
    registry="${imagename%%/*}"
    repo="${imagename#*/}"

    token="$(curl -fsSL --connect-timeout 10 --max-time 30 "https://${registry}/token?scope=repository:${repo}:pull" 2>/dev/null \
        | jq -r '.token // empty' 2>/dev/null)" || return 1
    [[ -n "$token" ]] || return 1

    digest="$(curl -fsS -I -X GET --connect-timeout 10 --max-time 30 \
        -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
        "https://${registry}/v2/${repo}/manifests/latest" 2>/dev/null \
        | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*//p')" || return 1
    [[ "$digest" =~ $DIGEST_RE ]] || return 1
    printf '%s' "$digest"
}

# check_freshness <catalog_file> — returns 0 in sync, 1 drift, 2 backend error.
check_freshness() {
    local file="$1" rc=0 drift=0 backend_err=0
    local tool delivery image imagename pinned resolved checked=0

    if [[ ! -f "$file" ]]; then
        printf 'check_catalog_freshness: catalog not found: %s\n' "$file" >&2
        return 2
    fi
    if ! jq -e . "$file" >/dev/null 2>&1; then
        printf 'check_catalog_freshness: %s is not valid JSON\n' "$file" >&2
        return 2
    fi

    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        delivery="$(read_catalog_field "$file" "$tool" delivery)"
        [[ "$delivery" == "image" ]] || continue
        image="$(read_catalog_field "$file" "$tool" image)"
        imagename="${image%@sha256:*}"
        pinned="${image##*@}"

        # Skip non-curated/adopter-override entries: their tag scheme is unknown.
        [[ "$imagename" =~ $CURATED_PREFIX_RE ]] || continue
        checked=$((checked + 1))

        if ! resolved="$(resolve_latest_digest "$imagename")"; then
            printf 'check_catalog_freshness: %s: could not resolve %s:latest from the registry\n' "$tool" "$imagename" >&2
            backend_err=1
            continue
        fi
        if [[ "$resolved" != "$pinned" ]]; then
            printf 'check_catalog_freshness: %s: catalog digest %s is behind :latest %s\n' "$tool" "$pinned" "$resolved" >&2
            printf '  remediation: tools/bump_catalog_digest.sh %s %s\n' "$tool" "$resolved" >&2
            drift=1
        fi
    done < <(jq -r '.tools // {} | keys[]' "$file")

    # A confirmed drift (1) wins over a transient backend error (2): the drift is
    # actionable regardless of another tool's reachability, and must not be masked.
    if [[ "$drift" -eq 1 ]]; then
        rc=1
    elif [[ "$backend_err" -eq 1 ]]; then
        rc=2
    else
        printf 'check_catalog_freshness: all %d curated image digest(s) match :latest\n' "$checked"
    fi
    return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$#" -gt 0 ]]; then
        printf 'Usage: %s   (catalog: WRANGLE_CATALOG env, else %s/catalog.json)\n' "${0##*/}" "$SCRIPT_DIR" >&2
        exit 2
    fi
    check_freshness "${WRANGLE_CATALOG:-$SCRIPT_DIR/catalog.json}"
fi
