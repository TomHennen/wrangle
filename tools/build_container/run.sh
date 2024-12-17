#!/bin/sh
set -e

echo "build_container"
# Build all the containers in /src - eventually, for now just build one... :)
cd /src
for path in `find . -name Dockerfile -maxdepth 2`
do
    subdir=$(dirname "$path")
    container_name=$(basename $subdir)
    docker buildx build --sbom=true -f $path -o type=tar,dest=/dist/$container_name.tar .
    tar xvf /dist/$container_name.tar sbom.spdx.json -C /metadata
done
