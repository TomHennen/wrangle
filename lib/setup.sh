#!/bin/bash
set -euo pipefail

# lib/setup.sh — Initialize wrangle directories.
#
# Sources lib/env.sh to define WRANGLE_BIN_DIR and WRANGLE_METADATA_DIR,
# then creates both directories. Called from the scan action's setup step.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

mkdir -p "$WRANGLE_BIN_DIR" "$WRANGLE_METADATA_DIR"
