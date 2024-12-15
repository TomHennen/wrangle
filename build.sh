#!/bin/bash                                                                                                                                                                      
set -e

# Pass tool names to build as an argument.
# e.g. build.sh foo bar

for tool in $@
do
    echo "Build $tool..."
    pushd tools/$tool
    docker buildx build -f Dockerfile -o type=docker -t tool_$tool .
    popd
    echo "$tool done"
done
