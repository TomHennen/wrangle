#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external file paths

# tools/osv/render_md.sh — Render osv-scanner SARIF as a markdown summary.
#
# osv-scanner SARIF needs an osv-specific renderer because the LCD helper at
# lib/sarif_to_md.sh drops the data that matters most for vuln triage:
#   1. Severity. osv emits result.level="warning" for every finding; real
#      CVSS lives at rule.properties["security-severity"].
#   2. Per-vuln dedupe. osv emits one result per (vuln, lockfile-location)
#      pair, so the same CVE appears N times. Old osv markdown deduped.
#   3. Fixed versions. osv embeds remediation guidance in rule.help.markdown
#      under "### Fixed Versions" — the most actionable column for users.
#
# Usage: render_md.sh <sarif_file>
# Output: Markdown table to stdout (sanitized + truncated via
#         wrangle_sanitize_output to prevent step-summary flooding).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../lib/sanitize.sh
source "$SCRIPT_DIR/../../lib/sanitize.sh"

if [[ $# -ne 1 ]]; then
    printf 'Usage: render_md.sh <sarif_file>\n' >&2
    exit 1
fi

SARIF_FILE="$1"

if [[ ! -f "$SARIF_FILE" ]]; then
    printf 'Error: SARIF file not found: %s\n' "$SARIF_FILE" >&2
    exit 1
fi

if ! jq empty "$SARIF_FILE" 2>/dev/null; then
    printf 'Error: invalid JSON in SARIF file: %s\n' "$SARIF_FILE" >&2
    exit 2
fi

# Map CVSS 3.x base score to severity label.
severity_label() {
    local score="$1"
    if [[ -z "$score" ]] || [[ "$score" == "null" ]]; then
        printf 'UNKNOWN'
        return
    fi
    awk -v s="$score" 'BEGIN {
        if (s+0 >= 9.0)      print "CRITICAL";
        else if (s+0 >= 7.0) print "HIGH";
        else if (s+0 >= 4.0) print "MEDIUM";
        else if (s+0 > 0)    print "LOW";
        else                 print "UNKNOWN";
    }'
}

# jq program kept in a heredoc to avoid quoting headaches around the single
# quotes osv puts in its message text (e.g. Package 'foo@1.2.3' ...).
# Everything is extracted inside jq so we never pass multi-line content like
# rule.help.markdown back through bash. Output is one TSV row per unique
# rule (= per unique vulnerability).
read -r -d '' JQ_PROG <<'JQ' || true
def esc: gsub("\\|"; "/") | gsub("\n"; " ") | gsub("\t"; " ");

# Quote characters used in osv message strings ("Package '...' is vulnerable").
# Inside the jq string, the literal " must be backslash-escaped; the
# apostrophe ' passes through unchanged.
def pkg_re: "Package ['\"]?(?<pkg>[^'\"]+)['\"]?";

def fixed_versions:
    # The "### Fixed Versions" section is a 3-column markdown table:
    # | VulnID | Package | Fixed Version |
    (split("### Fixed Versions") | .[1] // "")
    | (split("\n###") | (.[0] // ""))
    | [scan("\\|\\s*[^|\\n]+\\s*\\|\\s*([^|\\n]+?)\\s*\\|\\s*([^|\\n]+?)\\s*\\|")]
    | map(select(.[0] != "Package Name" and (.[0] | test("^-+$") | not)))
    | map(.[0] + "@" + .[1])
    | unique
    | join(", ");

.runs[0] as $run
| ($run.tool.driver.rules // []) as $rules
| ($run.results // []) as $results
| $rules
| map(
    . as $rule
    | ($results | map(select(.ruleId == $rule.id))) as $matches
    | select(($matches | length) > 0)
    | {
        ruleId: $rule.id,
        severity: ($rule.properties["security-severity"] // ""),
        packages: (
          $matches
          | map(.message.text | capture(pkg_re; "")? | .pkg // empty)
          | unique
          | join(", ")
        ),
        locations: (
          $matches
          | map(
              .locations[0].physicalLocation.artifactLocation.uri // "unknown"
              | sub("^file://"; "")
            )
          | unique
          | join(", ")
        ),
        fixed: (($rule.help.markdown // "") | fixed_versions)
      }
    | [
        (.ruleId    | esc),
        .severity,
        (.packages  | esc),
        (.fixed     | esc),
        (.locations | esc)
      ]
    # ASCII Unit Separator (U+001F). Non-whitespace so bash `read` with
    # IFS=$'\x1f' preserves empty fields (severity is often absent for
    # rules without a CVSS score).
    | join("")
  )
| .[]
JQ

records=$(jq -r "$JQ_PROG" "$SARIF_FILE")

if [[ -z "$records" ]]; then
    printf 'No known vulnerabilities.\n'
    exit 0
fi

{
printf '| Severity | Vulnerability | Package | Fixed Version(s) | Locations |\n'
printf '| -------- | ------------- | ------- | ---------------- | --------- |\n'

while IFS=$'\x1f' read -r ruleId severity packages fixed locations; do
    [[ -z "$ruleId" ]] && continue
    sev_label=$(severity_label "$severity")
    [[ -z "$fixed" ]] && fixed='—'
    [[ -z "$packages" ]] && packages='—'
    # shellcheck disable=SC2016 # backticks render as a markdown code span
    printf '| %s | %s | %s | %s | `%s` |\n' \
        "$sev_label" "$ruleId" "$packages" "$fixed" "$locations"
done <<< "$records"
} | wrangle_sanitize_output
