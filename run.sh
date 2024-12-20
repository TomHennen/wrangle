#!/bin/bash
set -e

# Pass tools to run as arguments.
# e.g. run.sh foo bar

mkdir ./metadata
SUMMARY_FILE=./metadata/summary.md
echo "| Tool | Status | Results |" >> $SUMMARY_FILE
echo "| ---- | ------ | ------- |" >> $SUMMARY_FILE
WRANGLE_EXIT_STATUS=0
for tool in $@;
do
    echo "Running $tool..."
    mkdir -p ./metadata/$tool
    mkdir -p ./dist/$tool
    TOOL_STATUS="Success"
    docker run \
       --quiet \
       --mount type=bind,source=./dist/$tool,target=/dist \
	   --mount type=bind,source=./metadata/$tool,target=/metadata \
	   --mount type=bind,source=./,target=/src,readonly \
       -v /var/run/docker.sock:/var/run/docker.sock \
	   ghcr.io/tomhennen/wrangle/$tool:main | tee ./metadata/$tool/output.txt || WRANGLE_EXIT_STATUS=1; TOOL_STATUS="Failed"
    echo "$tool $TOOL_STATUS"
    echo "| $tool | $TOOL_STATUS | <pre><code>`cat ./metadata/$tool/output.txt`</code></pre> |" >> $SUMMARY_FILE
done
echo "Done with all tools. Exiting with $WRANGLE_EXIT_STATUS"
exit $WRANGLE_EXIT_STATUS
