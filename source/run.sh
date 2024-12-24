#!/bin/bash

# Pass tools to run as arguments.
# e.g. run.sh foo bar
# Specify the repo to get the tools from with -r
# run.sh -r ghrc.io/tomhennen/wrangle foo bar

while getopts "r:" opt
do
   case "$opt" in
      r ) parameterReg="$OPTARG"
          shift
          shift;;
   esac
done

echo "Registry is '$parameterReg'"

mkdir -p ./metadata
WRANGLE_EXIT_STATUS=0
for tool in $@;
do
    echo "Running $tool..."
    mkdir -p ./metadata/$tool
    mkdir -p ./dist/$tool
    TOOL_STATUS="Success"

    # We don't want the pipe/tee output to make it look like this succeeded.
    set -o pipefail

    docker run \
       --quiet \
       --mount type=bind,source=./dist/$tool,target=/dist \
	   --mount type=bind,source=./metadata/$tool,target=/metadata \
	   --mount type=bind,source=./,target=/src,readonly \
       -v /var/run/docker.sock:/var/run/docker.sock \
	   "${parameterReg}/source/tools/${tool}:latest"
    if [ $? -ne 0 ]; then
        WRANGLE_EXIT_STATUS=1
        TOOL_STATUS="Failed"
    fi

    echo "$tool $TOOL_STATUS"
done

echo "Done with all tools. Exiting with $WRANGLE_EXIT_STATUS"
exit $WRANGLE_EXIT_STATUS
