#!/usr/bin/env bats

# Unit tests for the decision functions of tools/check_go_vulns.sh. Hermetic:
# each function is sourced in a subshell and driven with a fixture govulncheck
# JSON stream or osv config; the real scan (vuln database, network) is a CI job.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/tools/check_go_vulns.sh"
    CONFIG="$BATS_TEST_TMPDIR/osv-scanner.toml"
    JSON="$BATS_TEST_TMPDIR/govulncheck.json"
}

suppressed() {
    run bash -c 'source "$1"; suppressed_ids "$2" "$3"' -- "$SCRIPT" "$1" "$2"
}

reachable() {
    run bash -c 'source "$1"; reachable_ids "$2"' -- "$SCRIPT" "$1"
}

unreached() {
    run bash -c 'source "$1"; unreached_ids "$2"' -- "$SCRIPT" "$1"
}

@test "suppressed_ids: an unexpired entry suppresses" {
    printf '[[IgnoredVulns]]\nid = "GO-2026-5932"\nignoreUntil = 2026-10-11T00:00:00Z\nreason = "no fix upstream"\n' > "$CONFIG"
    suppressed "$CONFIG" "2026-09-20T00:00:00Z"
    [ "$status" -eq 0 ]
    [ "$output" = "GO-2026-5932" ]
}

@test "suppressed_ids: an expired entry no longer suppresses" {
    printf '[[IgnoredVulns]]\nid = "GO-2026-5932"\nignoreUntil = 2026-10-11T00:00:00Z\nreason = "no fix upstream"\n' > "$CONFIG"
    suppressed "$CONFIG" "2026-10-11T00:00:01Z"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "suppressed_ids: an entry with no ignoreUntil suppresses indefinitely" {
    printf '[[IgnoredVulns]]\nid = "GO-2026-6225"\nreason = "no fix upstream"\n' > "$CONFIG"
    suppressed "$CONFIG" "2099-01-01T00:00:00Z"
    [ "$status" -eq 0 ]
    [ "$output" = "GO-2026-6225" ]
}

@test "suppressed_ids: an id quoted inside a reason is not itself suppressed" {
    printf '[[IgnoredVulns]]\nid = "GO-2026-5932"\nignoreUntil = 2026-10-11T00:00:00Z\nreason = "supersedes id = \\"GO-1999-0001\\" upstream"\n' > "$CONFIG"
    suppressed "$CONFIG" "2026-09-20T00:00:00Z"
    [ "$status" -eq 0 ]
    [ "$output" = "GO-2026-5932" ]
}

@test "suppressed_ids: a bare date ignoreUntil is read as UTC midnight" {
    printf '[[IgnoredVulns]]\nid = "GO-2026-5932"\nignoreUntil = 2026-10-11\nreason = "no fix upstream"\n' > "$CONFIG"
    suppressed "$CONFIG" "2026-10-10T23:59:59Z"
    [ "$status" -eq 0 ]
    [ "$output" = "GO-2026-5932" ]

    suppressed "$CONFIG" "2026-10-11T00:00:01Z"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "suppressed_ids: an offset-less datetime ignoreUntil is read as UTC" {
    printf '[[IgnoredVulns]]\nid = "GO-2026-5932"\nignoreUntil = 2026-10-11T06:00:00\nreason = "no fix upstream"\n' > "$CONFIG"
    suppressed "$CONFIG" "2026-10-11T05:00:00Z"
    [ "$status" -eq 0 ]
    [ "$output" = "GO-2026-5932" ]
}

@test "suppressed_ids: an entry with no id fails closed" {
    printf '[[IgnoredVulns]]\nignoreUntil = 2026-10-11T00:00:00Z\nreason = "no fix upstream"\n' > "$CONFIG"
    suppressed "$CONFIG" "2026-09-20T00:00:00Z"
    [ "$status" -ne 0 ]
}

@test "suppressed_ids: an unparseable config fails closed" {
    printf 'this is not toml {{\n' > "$CONFIG"
    suppressed "$CONFIG" "2026-09-20T00:00:00Z"
    [ "$status" -ne 0 ]
}

@test "reachable_ids: reports symbol-level findings only" {
    {
        printf '{"config":{"scanner_name":"govulncheck"}}\n'
        printf '{"osv":{"id":"GO-1000-0001"}}\n'
        printf '{"finding":{"osv":"GO-1000-0001","trace":[{"module":"example.com/m"}]}}\n'
        printf '{"finding":{"osv":"GO-1000-0002","trace":[{"module":"example.com/m","package":"example.com/m/p"}]}}\n'
        printf '{"finding":{"osv":"GO-1000-0003","trace":[{"module":"example.com/m","package":"example.com/m/p","function":"Bad"}]}}\n'
    } > "$JSON"
    reachable "$JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "GO-1000-0003" ]
}

@test "reachable_ids: deduplicates an id reported on several traces" {
    {
        printf '{"finding":{"osv":"GO-1000-0003","trace":[{"module":"example.com/m","function":"A"}]}}\n'
        printf '{"finding":{"osv":"GO-1000-0003","trace":[{"module":"example.com/m","function":"B"}]}}\n'
    } > "$JSON"
    reachable "$JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "GO-1000-0003" ]
}

@test "reachable_ids: a scan with no findings reports nothing" {
    printf '{"config":{"scanner_name":"govulncheck"}}\n' > "$JSON"
    reachable "$JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "unreached_ids: reports module- and package-level findings" {
    {
        printf '{"config":{"scanner_name":"govulncheck"}}\n'
        printf '{"finding":{"osv":"GO-1000-0001","trace":[{"module":"example.com/m"}]}}\n'
        printf '{"finding":{"osv":"GO-1000-0002","trace":[{"module":"example.com/m","package":"example.com/m/p"}]}}\n'
    } > "$JSON"
    unreached "$JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "GO-1000-0001
GO-1000-0002" ]
}

@test "unreached_ids: an id also reported at symbol level is left to reachable_ids" {
    {
        printf '{"finding":{"osv":"GO-1000-0003","trace":[{"module":"example.com/m"}]}}\n'
        printf '{"finding":{"osv":"GO-1000-0003","trace":[{"module":"example.com/m","package":"example.com/m/p","function":"Bad"}]}}\n'
    } > "$JSON"
    unreached "$JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "the shipped osv config parses and names the known unfixable finding" {
    suppressed "$REPO_ROOT/tools/osv-scanner.toml" "1970-01-01T00:00:00Z"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GO-2026-5932"* ]]
}
