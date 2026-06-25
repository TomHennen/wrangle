#!/bin/bash
set -euo pipefail
set -f

# lib/setup.sh — Initialize wrangle directories and orchestrator infra.
#
# Sources lib/env.sh to define WRANGLE_BIN_DIR and WRANGLE_METADATA_DIR and
# creates both directories. Called from the scan action's setup step.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

mkdir -p "$WRANGLE_BIN_DIR" "$WRANGLE_METADATA_DIR"
