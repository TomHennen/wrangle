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
	   --mount type=bind,source=./,target=/src,readonly \
       -v /var/run/docker.sock:/var/run/docker.sock \
	   ghcr.io/tomhennen/wrangle/$tool:main
    echo "$tool done"
done
