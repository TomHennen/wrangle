#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input
# shellcheck disable=SC2016
# Missing inline justification — WSL005 positive fixture.
printf 'result: %s\n' '$not_expanded'
