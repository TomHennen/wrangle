#!/bin/bash
set -euo pipefail
set -f  # disable globbing — processes external input paths

# Mock tool honoring the wrangle adapter contract, used only to test the image
# harness (test/lib/image_test_harness.sh). A real tool can't produce a
# controlled exit-2 / malformed-SARIF on demand, so a mock drives each path.
# Behavior is selected by the contents of <src>/MODE.

src="$1"
out="$2"
mode="$(cat "$src/MODE" 2>/dev/null || printf 'clean')"

case "$mode" in
    findings)
        printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"mock"}},"results":[{"ruleId":"X"}]}]}\n' > "$out/output.sarif"
        exit 1 ;;
    error)
        printf 'mock: simulated tool error\n' >&2
        exit 2 ;;
    malformed)
        printf 'not valid json{' > "$out/output.sarif"
        exit 0 ;;
    secret)
        # Record forwarded secret env vars so a test can assert each arrived.
        # MOCK_SECRET covers a generic secret name; GITHUB_TOKEN is the name the
        # github-token catalog secret (e.g. zizmor's) bridges to.
        printf '%s' "${MOCK_SECRET:-}" > "$out/secret_seen"
        printf '%s' "${GITHUB_TOKEN:-}" > "$out/github_token_seen"
        printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"mock"}},"results":[]}]}\n' > "$out/output.sarif"
        exit 0 ;;
    netcheck)
        # Record the container's network interfaces. With --network none only
        # loopback exists, so a test can assert egress is closed by default.
        (ls /sys/class/net 2>/dev/null || printf '') > "$out/net_ifaces"
        printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"mock"}},"results":[]}]}\n' > "$out/output.sarif"
        exit 0 ;;
    *)
        printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"mock"}},"results":[]}]}\n' > "$out/output.sarif"
        exit 0 ;;
esac
