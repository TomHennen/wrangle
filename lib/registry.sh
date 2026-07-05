#!/bin/bash
# lib/registry.sh — shared GHCR helpers for the curated tool catalog.
#
# Provides:
#   resolve_latest_digest — anonymous GHCR digest of an <image>:latest tag
# plus the two regexes its callers share:
#   CURATED_PREFIX_RE     — wrangle's own image namespace (adopter overrides excluded)
#   DIGEST_RE             — a well-formed sha256 image digest

set -euo pipefail
set -f  # disable globbing — handles external image names

# Tool segment matches run.sh's tool-name shape, so a crafted `..` segment can't
# turn curl's path into a cross-repo query.
CURATED_PREFIX_RE='^ghcr\.io/tomhennen/wrangle/[a-z][a-z0-9_-]*$'
DIGEST_RE='^sha256:[0-9a-f]{64}$'

# is_curated_image <imagename> — true if <imagename> is on wrangle's own curated
# namespace. An adopter-override image (a foreign namespace) is not, so callers
# skip it: wrangle vouches only for the images it publishes.
is_curated_image() {
    [[ "$1" =~ $CURATED_PREFIX_RE ]]
}

# resolve_latest_digest <imagename> — anonymous GHCR digest of <imagename>:latest
# via the registry API. Prints the index digest on success; non-zero on any
# backend failure (token fetch, registry read, or a missing/malformed digest).
# The index media types in Accept return the same multi-arch index digest the
# catalog pins.
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
