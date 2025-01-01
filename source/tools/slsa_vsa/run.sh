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
# --output-attestation doesn't output the signed DSSE (but strangely the signed DSSE is sent to STDOUT).
# So instead we write vsa.bundle which is a _Sigstore_ bundle and contains the DSSE.
# run.sh is provided as the filename to compute the hash over even though we override the hash on the command line.
# (otherwise we get errors).
# Unfortunately this still doesn't work as is.  We're providing an in-toto _Statement_ not a predicate and we
# _have to_ provide the entire statement since a SLSA Source VSA requires a gitCommit as the digest type and
# we want to add annotations in the subject field. `attest-blob` doesn't let us do either of those things right
# now.  So currently this embeds and entire statement inside a predicate field with the wrong subject.
# We'll have to find some other way to sign things.
echo $UNSIGNED_VSA | cosign attest-blob --type https://slsa.dev/verification_summary/v1 --hash "$1" --output-attestation vsa.att --bundle vsa.bundle --new-bundle-format=true --yes --predicate - run.sh

