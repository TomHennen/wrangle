#!/bin/bash
set -e

# Pass tools to run as arguments.
# e.g. run.sh foo bar

WRANGLE_EXIT_STATUS=0
for tool in $@;
do
    echo "Running $tool..."
    mkdir -p ./metadata/$tool
    mkdir -p ./dist/$tool
    docker run \
       --quiet \
       --mount type=bind,source=./dist/$tool,target=/dist \
	   --mount type=bind,source=./metadata/$tool,target=/metadata \
	   --mount type=bind,source=./,target=/src,readonly \
       -v /var/run/docker.sock:/var/run/docker.sock \
	   ghcr.io/tomhennen/wrangle/$tool:main || echo "$tool failed" && WRANGLE_EXIT_STATUS=1
    echo "$tool done"
done
exit $WRANGLE_EXIT_STATUS
