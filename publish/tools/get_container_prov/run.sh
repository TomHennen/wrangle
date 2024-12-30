#!/bin/sh
set -e

IMAGE_URI=$1

echo "Getting attestations for ${IMAGE_URI}..."

cosign download attestation ${IMAGE_URI} > /metadata/container.intoto.jsonl
