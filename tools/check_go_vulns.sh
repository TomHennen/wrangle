#!/bin/bash
set -euo pipefail
set -f  # disable globbing — handles vulnerability ids from tool output

# tools/check_go_vulns.sh — reachable-vulnerability gate for wrangle's own Go
# tools. Runs the govulncheck pinned by tools/go.mod over that module's
# packages and fails on any symbol-reachable finding that tools/osv-scanner.toml
# does not currently suppress, so the osv allowlist is the single source for
# both scanners.
#
# Needs the vulnerability database, so this is an integration check: CI runs it
# per PR, and it runs locally whenever the network is available.
#
# Exit: 0 clean, 1 an unsuppressed reachable vulnerability, 2 env error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSV_CONFIG="$SCRIPT_DIR/osv-scanner.toml"
JSON_OUT=""

# Vulnerability ids the osv config still suppresses at <now> (RFC 3339 UTC). An
# entry whose ignoreUntil has passed no longer suppresses, matching osv-scanner:
# the expiry is a forced-revisit tripwire, not an inherited pass.
suppressed_ids() {
    local config="$1" now="$2"
    python3 -c '
import datetime, sys, tomllib

with open(sys.argv[1], "rb") as fh:
    config = tomllib.load(fh)
now = datetime.datetime.fromisoformat(sys.argv[2])
for entry in config.get("IgnoredVulns", []):
    until = entry.get("ignoreUntil")
    if until is None or until > now:
        print(entry["id"])
' "$config" "$now"
}

# Vulnerability ids govulncheck found reachable: a trace whose innermost frame
# names a function is its symbol level, the only one that proves a call path.
reachable_ids() {
    jq -rs '[.[] | select(.finding.trace[0].function != null) | .finding.osv] | unique | .[]' "$1"
}

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'check_go_vulns: %s is required but not installed.\n' "$1" >&2
        exit 2
    fi
}

main() {
    require_tool go
    require_tool jq
    require_tool python3

    JSON_OUT="$(mktemp)"
    trap 'rm -f "$JSON_OUT"' EXIT

    printf 'check_go_vulns: scanning tools/... with the govulncheck pinned in tools/go.mod\n'
    # Assert the proxy and sum database so the inherited environment cannot
    # silently weaken the integrity check on the tool's own build.
    GOPROXY="https://proxy.golang.org,direct" GOSUMDB="sum.golang.org" \
        go -C "$SCRIPT_DIR" tool govulncheck -format json ./... >"$JSON_OUT"

    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local suppressed_list reachable_list
    suppressed_list="$(suppressed_ids "$OSV_CONFIG" "$now" | LC_ALL=C sort -u)"
    reachable_list="$(reachable_ids "$JSON_OUT" | LC_ALL=C sort -u)"

    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        printf 'check_go_vulns: %s is reachable but suppressed by tools/osv-scanner.toml\n' "$id"
    done < <(comm -12 <(printf '%s\n' "$reachable_list") <(printf '%s\n' "$suppressed_list"))

    local -a unsuppressed=()
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        unsuppressed+=("$id")
    done < <(comm -23 <(printf '%s\n' "$reachable_list") <(printf '%s\n' "$suppressed_list"))

    if (( ${#unsuppressed[@]} == 0 )); then
        printf 'check_go_vulns: no unsuppressed reachable vulnerabilities.\n'
        return 0
    fi

    printf 'check_go_vulns: reachable vulnerabilities with no entry in tools/osv-scanner.toml:\n' >&2
    for id in "${unsuppressed[@]}"; do
        printf '  %s  https://pkg.go.dev/vuln/%s\n' "$id" "$id" >&2
    done
    printf 'Upgrade the affected module, or — if upstream has no fix — add an [[IgnoredVulns]]\n' >&2
    printf 'entry with a reason and an ignoreUntil to tools/osv-scanner.toml.\n' >&2
    printf 'Traces: go -C tools tool govulncheck ./...\n' >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
