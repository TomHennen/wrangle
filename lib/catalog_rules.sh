#!/bin/bash
# shellcheck disable=SC2034 # constants are consumed by the scripts that source this file
set -euo pipefail
set -f  # disable globbing — sourced constants, no external input

# lib/catalog_rules.sh — shared validation constants for catalog entries, so the
# curated-catalog linter (tools/check_catalog.sh) and the custom-tools validator
# (lib/merge_catalog.sh) enforce one set of value rules. Namespace/trust rules
# differ between them and stay in each caller.

# Tool name: the shape run.sh admits — no leading dot/dash, no path traversal.
CATALOG_TOOL_NAME_RE='^[a-z][a-z0-9_-]*$'
CATALOG_KIND_RE='^(scan|sbom|attest)$'
CATALOG_NETWORK_RE='^(none|egress)$'
CATALOG_SECRET_NAME_RE='^[a-z][a-z0-9-]*$'
# Digest-pinned image, host-agnostic (the registry may carry a :port). Curated
# entries additionally require the wrangle namespace; check_catalog enforces that.
CATALOG_IMAGE_DIGEST_RE='^[a-z0-9._-]+(:[0-9]+)?(/[a-z0-9._-]+)*@sha256:[0-9a-f]{64}$'
