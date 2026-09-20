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

# osv-scanner documents ignoreUntil as a bare date; TOML also admits a datetime,
# with or without an offset. Normalise all three to an aware UTC datetime.
def as_utc(value):
    if not isinstance(value, datetime.datetime):
        value = datetime.datetime.combine(value, datetime.time.min)
    if value.tzinfo is None:
        value = value.replace(tzinfo=datetime.timezone.utc)
    return value

with open(sys.argv[1], "rb") as fh:
    config = tomllib.load(fh)
now = as_utc(datetime.datetime.fromisoformat(sys.argv[2]))
for entry in config.get("IgnoredVulns", []):
    until = entry.get("ignoreUntil")
    if until is None or as_utc(until) > now:
        print(entry["id"])
' "$config" "$now"
}

# Vulnerability ids govulncheck proved a call path to: a trace whose innermost
# frame names a function is its symbol level. Module- and package-level findings
# are excluded — see unreached_ids, which reports them instead.
reachable_ids() {
    jq -rs '[.[] | select(.finding.trace[0].function != null) | .finding.osv] | unique | .[]' "$1"
}

# Vulnerability ids reported only below the symbol level. Module level is how
# govulncheck reports an advisory carrying no affected symbol — a Go toolchain
# advisory among them — so these are surfaced rather than dropped.
unreached_ids() {
    jq -rs '
        [.[] | select(.finding != null) | .finding] as $findings
        | ([$findings[] | select(.trace[0].function != null) | .osv] | unique) as $called
        | [$findings[] | select(.trace[0].function == null) | .osv]
        | unique | map(select(IN($called[]) | not)) | .[]' "$1"
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

    local suppressed_list reachable_list unreached_list
    suppressed_list="$(suppressed_ids "$OSV_CONFIG" "$now" | LC_ALL=C sort -u)"
    reachable_list="$(reachable_ids "$JSON_OUT" | LC_ALL=C sort -u)"
    unreached_list="$(unreached_ids "$JSON_OUT" | LC_ALL=C sort -u)"

    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        printf 'check_go_vulns: %s is reachable but suppressed by tools/osv-scanner.toml\n' "$id"
    done < <(comm -12 <(printf '%s\n' "$reachable_list") <(printf '%s\n' "$suppressed_list"))

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        printf 'check_go_vulns: warning: %s affects a required module but govulncheck traced no call to it — https://pkg.go.dev/vuln/%s\n' "$id" "$id" >&2
    done < <(comm -23 <(printf '%s\n' "$unreached_list") <(printf '%s\n' "$suppressed_list"))

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
