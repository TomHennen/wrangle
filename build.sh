#!/bin/bash                                                                                                                                                                      
set -e

# Pass tool names to build as an argument.
# e.g. build.sh foo bar

# TODO: Have this use build_container...

for tool in $@
do
    echo "Build $tool..."
    pushd tools/$tool
    docker buildx build --sbom=true -f Dockerfile -o type=docker -t tool_$tool .
    popd
    echo "$tool done"
done
