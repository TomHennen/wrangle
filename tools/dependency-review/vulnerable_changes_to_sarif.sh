#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external tool output

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
#       "scope": "runtime" | "development" | "unknown",
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
# Scope policy: a vulnerable change is converted regardless of its
# `scope` — a vulnerable development/build-time dependency is flagged
# exactly like a runtime one. This is deliberate: the default policy is
# to block on any introduced vulnerability, and "flag, don't guess" is
# the conservative choice. If wrangle later wants scope-aware policy
# (e.g. don't block on dev-only deps, like dependency-review-action's
# `fail-on-scopes`), `scope` is the field to branch on.
#
# Usage: vulnerable_changes_to_sarif.sh <json_file>
# Output: SARIF 2.1.0 JSON to stdout.
# Exit: 0 on success (including no findings), 1 on missing/unreadable input,
#       2 on invalid JSON or jq filter failure.

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
# Pass the literal "[]" to jq via stdin rather than mutating the caller's
# file — surprise side effects on inputs are a footgun.
INPUT_SIZE=$(wc -c < "$JSON_FILE")
if [[ "$INPUT_SIZE" -eq 0 ]]; then
    json_input='[]'
else
    if ! jq empty "$JSON_FILE" 2>/dev/null; then
        printf 'Error: invalid JSON in %s\n' "$JSON_FILE" >&2
        exit 2
    fi
    json_input="$(cat "$JSON_FILE")"
fi

# jq filter does the heavy lifting:
#   - severity → SARIF level and numeric security-severity. Unknown
#     severities fall back to "note" / "0.0" so unexpected upstream
#     output is surfaced rather than silently mapped to a high level.
#   - rules: one per unique GHSA id
#   - results: one per (change, vulnerability)
#   - every change EXCEPT change_type "removed" is converted. A
#     "removed" entry means the PR drops a vulnerable dependency —
#     that must not block the PR. The test is `!= "removed"` rather
#     than `== "added"` so it fails safe: change_type is currently
#     enum(added, removed), but should the upstream schema gain a new
#     value, a vulnerable change of that type is still surfaced rather
#     than silently dropped. A missing or null change_type is likewise
#     not "removed", so it too is surfaced.
# Empty advisory_url / advisory_summary are omitted (SARIF requires
# helpUri to be a valid URI when present; empty strings fail strict
# validators). helpUri lives on the rule ONLY: SARIF allows it solely on
# reportingDescriptor, and GitHub's code-scanning upload rejects a result
# carrying it ("not allowed to have the additional property helpUri").
# shellcheck disable=SC2016 # $pairs is a jq variable, not bash — single quotes intentional
SARIF_FILTER='
  def sarif_level(s):
    if   s == "critical" then "error"
    elif s == "high"     then "error"
    elif s == "moderate" then "warning"
    elif s == "low"      then "note"
    else "note"
    end;

  def security_severity(s):
    if   s == "critical" then "9.5"
    elif s == "high"     then "7.5"
    elif s == "moderate" then "5.0"
    elif s == "low"      then "2.5"
    else "0.0"
    end;

  [ .[]
    | select(.change_type != "removed") as $c
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
                | (
                    {
                      id: .vuln.advisory_ghsa_id,
                      name: .vuln.advisory_ghsa_id
                    }
                    + (if (.vuln.advisory_summary // "") != ""
                        then {shortDescription: {text: .vuln.advisory_summary}}
                        else {} end)
                    + (if (.vuln.advisory_url // "") != ""
                        then {helpUri: .vuln.advisory_url}
                        else {} end)
                  )
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
                "security-severity": security_severity(.vuln.severity),
                ghsa_id: (.vuln.advisory_ghsa_id // ""),
                package: ("\(.change.ecosystem // "?"):\(.change.name)@\(.change.version)"),
                ecosystem: (.change.ecosystem // ""),
                change_type: (.change.change_type // "")
              }
            }
        ]
      }]
    }
'

# Buffer the jq output so a filter failure does not leave a partially-
# written SARIF on stdout (or in the caller's redirect target).
if ! sarif_out="$(printf '%s' "$json_input" | jq "$SARIF_FILTER" 2>/dev/null)"; then
    printf 'Error: jq filter failed while converting to SARIF\n' >&2
    exit 2
fi
printf '%s\n' "$sarif_out"
