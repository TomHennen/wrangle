#!/bin/sh
set -e

# Usage:
# ./run.sh <COMMIT> <REPO> <BRANCH>

# TODO: add support for multiple branches

TIME_VERIFIED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Create the unsigned vsa
echo "Create unsigned source VSA"
UNSIGNED_VSA=$(jq -n --arg subjectCommit $1 --arg subjectRepo $2 --arg subjectBranch $3 --arg timeVerified $TIME_VERIFIED -f vsa_template.jq)

echo $UNSIGNED_VSA

echo "Sign it"
echo $UNSIGNED_VSA | cosign attest-blob --type https://slsa.dev/verification_summary/v1 --hash $1 --output-attestation vsa.att --yes --predicate - run.sh


