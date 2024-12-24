# Summary table...
echo "# Wrangle results"
echo "| Tool | Status | Results |"
echo "| ---- | ------ | ------- |"
TOOLS=$(find 'metadata' -maxdepth 1 -type d)
for dir in $TOOLS;
do
    tool=$(basename $dir)
    TOOL_STATUS="No findings"
    if [ -f ./metadata/$tool/$tool.sarif ]; then
        NUM_FINDINGS=$(jq '[.runs[].results[]] | length' ./metadata/$tool/$tool.sarif)
        if [ $NUM_FINDINGS -gt 0 ]; then
            TOOL_STATUS="$NUM_FINDINGS findings"
        fi
    fi

    echo "| $tool | $TOOL_STATUS | [Details](#$tool-details) |"
done

printf "\n"

# Get the details...
for dir in $TOOLS;
do
    tool=$(basename $dir)
    echo "## $tool Details"
    if [ -f ./metadata/$tool/output.txt ]; then
        printf "\n<pre><code>"
        cat ./metadata/$tool/output.txt
        printf "</code></pre>\n"
    elif [ -f ./metadata/$tool/output.md ]; then
        cat ./metadata/$tool/output.md
    fi
    printf "\n"
done
