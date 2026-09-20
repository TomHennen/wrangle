#!/bin/bash
set -euo pipefail
set -f

# lib/tracking_tag.sh — the wrangle-test tracking-tag shape (vYYYYMMDD-<7-hex
# wrangle sha>, docs/RELEASING.md). Shared by the producer
# (test/integration/push_showcase_tag.sh) and any consumer that needs to
# recognize one (tools/check_showcase_run_green.sh), so the two can't diverge.

export WRANGLE_TRACKING_TAG_RE='^v[0-9]{8}-[0-9a-f]{7}$'
