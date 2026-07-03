#!/bin/bash
# shellcheck disable=SC2034 # constants are consumed by the scripts that source this file
set -euo pipefail
set -f  # disable globbing — sourced constants, no external input

# lib/catalog_rules.sh — shared validation constants for catalog entries, used by
# run.sh, the curated-catalog linter (tools/check_catalog.sh), and the
# custom-tools validator (lib/merge_catalog.sh). The direction of the namespace
# rule differs per caller (curated entries MUST be in the namespace; custom
# entries MUST NOT be), so each caller applies the prefix itself.

# Tool name: the shape run.sh admits — no leading dot/dash, no path traversal.
CATALOG_TOOL_NAME_RE='^[a-z][a-z0-9_-]*$'
CATALOG_KIND_RE='^(scan|sbom|attest)$'
CATALOG_NETWORK_RE='^(none|egress)$'
CATALOG_SECRET_NAME_RE='^[a-z][a-z0-9-]*$'
# Digest-pinned image, host-agnostic (the registry may carry a :port).
CATALOG_IMAGE_DIGEST_RE='^[a-z0-9._-]+(:[0-9]+)?(/[a-z0-9._-]+)*@sha256:[0-9a-f]{64}$'
# Namespace of wrangle-published, VSA-signed tool images.
CATALOG_CURATED_IMAGE_PREFIX='ghcr.io/tomhennen/wrangle/'
