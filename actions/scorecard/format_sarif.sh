# Take the Scorecards sarif results and make them a bit easier to read.
echo "## Scorecard Details"
echo ""
echo "| Rule Name | Location | Message |"
echo "| --------- | -------- | ------- |"
jq '[.runs[].results[] | {rule: .ruleId, message: .message.text, locations: .locations[].physicalLocation.artifactLocation.uri }] | .[] | "| \(.rule) | \(.locations) | \(.message) |"' $1
