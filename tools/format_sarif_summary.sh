# Summary table...
echo "# Wrangle results"
echo "| Tool | Status | Results |"
echo "| ---- | ------ | ------- |"
for dir in metadata/*/
do
    tool=$(basename $dir)
    if [ -f ./metadata/$tool/output.sarif ]; then    
        TOOL_STATUS="No findings"
        NUM_FINDINGS=$(jq '[.runs[].results[]] | length' ./metadata/$tool/output.sarif)
        if [ $NUM_FINDINGS -gt 0 ]; then
            TOOL_STATUS="$NUM_FINDINGS findings"
        fi
        echo "| $tool | $TOOL_STATUS | [Details](#$tool-details) |"
    fi
done

printf "\n"

# Get the details...
for dir in metadata/*/
do
    tool=$(basename $dir)
    if [ -f ./metadata/$tool/output.txt ]; then
        echo "## $tool Details"
        printf "\n<pre><code>"
        cat ./metadata/$tool/output.txt
        printf "</code></pre>\n"
    elif [ -f ./metadata/$tool/output.md ]; then
        echo "## $tool Details"
        cat ./metadata/$tool/output.md
        printf "\n"
    fi
done
