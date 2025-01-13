#!/bin/bash


# Scans the provided SBOM and outputs sarif.
#
# Specify the repo to get the tools from with -r
# Specify the path to the SBOM to scan with -s
# Specify SBOM tools to run as arguments.
# run.sh -r ghrc.io/tomhennen/wrangle -s ./metadata/foo/sbom.spdx.json foo bar

while getopts "r:s:" opt; do
   case "$opt" in
        s) parameterSbom="$OPTARG";;
        r) parameterReg="$OPTARG/";;
   esac
done

shift $((OPTIND-1))

echo "Registry is '$parameterReg'"
echo "SBOM is '$parameterSbom'"

mkdir -p ./metadata
WRANGLE_EXIT_STATUS=0
for tool in $@;
do
    echo "Running SBOM $tool..."
    mkdir -p ./metadata/$tool
    TOOL_STATUS="Success"

    # We don't want the pipe/tee output to make it look like this succeeded.
    set -o pipefail

    docker run \
       --quiet \
	   --mount type=bind,source=./metadata,target=/metadata \
       -v /var/run/docker.sock:/var/run/docker.sock \
	   "${parameterReg}tools/${tool}:latest" $parameterSbom
    if [ $? -ne 0 ]; then
        WRANGLE_EXIT_STATUS=1
        TOOL_STATUS="Failed"
    fi

    echo "$tool $TOOL_STATUS"
done

echo "Done with all tools. Exiting with $WRANGLE_EXIT_STATUS"
exit $WRANGLE_EXIT_STATUS
