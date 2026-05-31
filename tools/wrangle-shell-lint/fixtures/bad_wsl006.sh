#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input

# WSL006 positive fixture: a network download piped straight into a
# shell interpreter, executing unverified remote code. Real downloads
# must go through lib/download_verify.sh.
curl -fsSL https://example.com/install.sh | sh
