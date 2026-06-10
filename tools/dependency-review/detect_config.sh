#!/bin/bash
set -euo pipefail
set -f

# Emit the workspace-relative path of actions/dependency-review-action's
# native config file to GITHUB_OUTPUT, or an empty path when the repo has
# none — upstream treats an empty config-file input as "not provided".
# Both conventional extensions are accepted (.yml preferred). The result
# is logged either way so a found-but-ignored config is observable.
# Tools honor their native config files rather than having every option
# plumbed through actions/scan (#221).

for p in .github/dependency-review-config.yml .github/dependency-review-config.yaml; do
    if [[ -f "$p" ]]; then
        printf 'path=./%s\n' "$p" >> "$GITHUB_OUTPUT"
        printf 'dependency-review: using native config %s\n' "$p"
        exit 0
    fi
done
printf 'path=\n' >> "$GITHUB_OUTPUT"
printf 'dependency-review: no native config file found\n'
