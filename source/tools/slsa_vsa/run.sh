#!/bin/sh
set -e

# Usage:
# ./run.sh <COMMIT> <REPO> <BRANCH>

# TODO: add support for multiple branches

TIME_VERIFIED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Create the unsigned vsa
jq -n --arg subjectCommit $1 --arg subjectRepo $2 --arg subjectBranch $3 --arg timeVerified $TIME_VERIFIED -f vsa_template.jq
