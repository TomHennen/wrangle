#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input
# Uses echo with variable interpolation — WSL003 positive fixture.

name="world"
echo "Hello $name"
