#!/bin/bash
set -e

# Pass tools to run as arguments.
# e.g. run.sh foo bar

for tool in $@;
do
    echo "Running $tool..."
    mkdir -p ./metadata/$tool
    mkdir -p ./dist/$tool
    docker run \
       --mount type=bind,source=./dist/$tool,target=/dist \
	   --mount type=bind,source=./metadata/$tool,target=/metadata \
	   --mount type=bind,source=./src,target=/src,readonly \
       -v /var/run/docker.sock:/var/run/docker.sock \
	   tool_$tool
    echo "$tool done"
done
