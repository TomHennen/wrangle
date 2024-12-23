# Take the Scorecards sarif results and make them a bit easier to read.
echo "Rule Name | Location | Message"
echo "--------- | -------- | -------"
jq '[.runs[].results[] | {rule: .ruleId, message: .message.text, locations: .locations[].physicalLocation.artifactLocation.uri }] | .[] | @html "\(.rule) | \(.locations) | \(.message)"' $1 | cut -d '"' -f 2
