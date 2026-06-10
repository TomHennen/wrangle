#!/bin/bash
set -euo pipefail
set -f

# Emit the workspace-relative path of actions/dependency-review-action's
# native config file to GITHUB_OUTPUT, or an empty path when the repo has
# none — upstream treats an empty config-file input as "not provided".
# Tools honor their native config files rather than having every option
# plumbed through actions/scan (#221).

p=".github/dependency-review-config.yml"
if [[ -f "$p" ]]; then
    printf 'path=./%s\n' "$p" >> "$GITHUB_OUTPUT"
else
    printf 'path=\n' >> "$GITHUB_OUTPUT"
fi
