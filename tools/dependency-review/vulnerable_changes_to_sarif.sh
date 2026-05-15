#!/bin/bash
set -euo pipefail

# Convert actions/dependency-review-action's `vulnerable-changes` JSON
# output into SARIF 2.1.0. Each (change, vulnerability) pair becomes one
# SARIF result; each unique GHSA becomes one SARIF rule.
#
# Input JSON schema (per dep-review's ChangeSchema):
#   [
#     {
#       "change_type": "added" | "removed",
#       "manifest": "<path>",
#       "ecosystem": "<eco>",
#       "name": "<pkg>",
#       "version": "<ver>",
#       "package_url": "<purl>",
#       "vulnerabilities": [
#         {
#           "severity": "low|moderate|high|critical",
#           "advisory_ghsa_id": "GHSA-...",
#           "advisory_summary": "<text>",
#           "advisory_url": "<url>"
#         }
#       ]
#     },
#     ...
#   ]
#
# Usage: vulnerable_changes_to_sarif.sh <json_file>
# Output: SARIF 2.1.0 JSON to stdout.

if [[ $# -ne 1 ]]; then
    printf 'Usage: vulnerable_changes_to_sarif.sh <json_file>\n' >&2
    exit 1
fi

JSON_FILE="$1"

if [[ ! -f "$JSON_FILE" ]]; then
    printf 'Error: input file not found: %s\n' "$JSON_FILE" >&2
    exit 1
fi

# An empty file (no output from dep-review) means no vulnerable changes.
# Normalise to an empty JSON array.
if [[ ! -s "$JSON_FILE" ]]; then
    printf '[]' > "$JSON_FILE"
fi

if ! jq empty "$JSON_FILE" 2>/dev/null; then
    printf 'Error: invalid JSON in %s\n' "$JSON_FILE" >&2
    exit 2
fi

# jq does the heavy lifting:
#   - severity → SARIF level (critical/high → error, moderate → warning, low/* → note)
#   - rules: one per unique GHSA id
#   - results: one per (change, vulnerability)
jq '
  # Severity → SARIF level
  def sarif_level(s):
    if   s == "critical" then "error"
    elif s == "high"     then "error"
    elif s == "moderate" then "warning"
    else "note"
    end;

  # Flatten to (change, vuln) pairs first; downstream rules/results
  # both consume this list.
  [ .[] as $c
    | ($c.vulnerabilities // [])[]
    | {change: $c, vuln: .}
  ] as $pairs

  | {
      version: "2.1.0",
      "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
      runs: [{
        tool: {
          driver: {
            name: "dependency-review",
            informationUri: "https://github.com/actions/dependency-review-action",
            rules: (
              [ $pairs[]
                | {
                    id: .vuln.advisory_ghsa_id,
                    name: .vuln.advisory_ghsa_id,
                    shortDescription: { text: (.vuln.advisory_summary // "") },
                    helpUri: (.vuln.advisory_url // "")
                  }
              ]
              | unique_by(.id)
            )
          }
        },
        results: [
          $pairs[]
          | {
              ruleId: .vuln.advisory_ghsa_id,
              level: sarif_level(.vuln.severity),
              message: {
                text: ("\(.vuln.advisory_summary // "Vulnerability") in \(.change.ecosystem // "?"):\(.change.name)@\(.change.version) (severity: \(.vuln.severity // "unknown"))")
              },
              locations: [{
                physicalLocation: {
                  artifactLocation: { uri: (.change.manifest // "") }
                }
              }],
              properties: {
                "security-severity": (
                  if   .vuln.severity == "critical" then "9.5"
                  elif .vuln.severity == "high"     then "7.5"
                  elif .vuln.severity == "moderate" then "5.0"
                  elif .vuln.severity == "low"      then "2.5"
                  else "0.0"
                  end
                ),
                ghsa_id: (.vuln.advisory_ghsa_id // ""),
                package: ("\(.change.ecosystem // "?"):\(.change.name)@\(.change.version)"),
                ecosystem: (.change.ecosystem // ""),
                change_type: (.change.change_type // "")
              },
              helpUri: (.vuln.advisory_url // "")
            }
        ]
      }]
    }
' "$JSON_FILE"
