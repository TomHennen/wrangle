#!/bin/bash
set -e

# Pass tools to run as arguments.
# e.g. run.sh foo bar

mkdir ./metadata
SUMMARY_FILE=./metadata/summary.md
echo "# Wrangle results" >> $SUMMARY_FILE
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
    cat ./metadata/$tool/output.txt
    echo "| $tool | $TOOL_STATUS | [Details](#$tool-details) |" >> $SUMMARY_FILE
done

echo "" >> $SUMMARY_FILE

# Add in the details
for tool in $@;
do
    echo "## $tool Details" >> $SUMMARY_FILE
    echo "" # Maybe replace with printfs?
    echo "```" >> $SUMMARY_FILE
    ls -l ./metadata/$tool/output.txt
    cat ./metadata/$tool/output.txt >> $SUMMARY_FILE
    echo "```" >> $SUMMARY_FILE
    echo "" >> $SUMMARY_FILE
done
echo "Done with all tools. Exiting with $WRANGLE_EXIT_STATUS"
exit $WRANGLE_EXIT_STATUS
