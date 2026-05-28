#!/usr/bin/env bats

# Structural tests for actions/install_slsa_verifier/action.yml.
#
# This composite is the single source of truth for the upstream
# slsa-verifier installer pin. The "no other callsite" test below is
# the load-bearing one — it's how the "pins drift across files" rule
# (CLAUDE.md) is mechanically enforced for this pin.

setup() {
    ACTION_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$ACTION_DIR/../.." && pwd)"
}

@test "install_slsa_verifier: composite invokes the upstream installer" {
    run grep -E 'uses:[[:space:]]*slsa-framework/slsa-verifier/actions/installer@' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "install_slsa_verifier: composite is the only file referencing the upstream installer" {
    # CLAUDE.md "pins drift across files": consolidate to a single source
    # or fail on divergence. Here we consolidate — every wrangle caller
    # goes through this composite, so no other file in the repo should
    # mention the upstream installer in a `uses:` line. We exclude the
    # composite itself, the test, and .git/. Filesystem-only (no git) so
    # the test works inside Docker, where this worktree's .git pointer
    # is dangling.
    run bash -c "
        grep -rlE 'uses:[[:space:]]*slsa-framework/slsa-verifier/actions/installer@' \"$REPO_ROOT\" \
            --exclude-dir=.git \
            --exclude-dir=install_slsa_verifier \
            2>/dev/null || true
    "
    [ -z "$output" ]
}

@test "install_slsa_verifier: every upstream-installer ref in the composite uses the same SHA" {
    # Three `uses:` lines invoke the upstream installer (initial + two
    # retries). If a future bump touches only one of them, the retry
    # path would install a different version than the primary attempt.
    pins=$(grep -oE 'slsa-framework/slsa-verifier/actions/installer@[0-9a-f]{40}' "$ACTION_DIR/action.yml" | sort -u)
    count=$(printf '%s\n' "$pins" | wc -l)
    [ "$count" -eq 1 ]
}

@test "install_slsa_verifier: final retry has no continue-on-error (must fail the job)" {
    # If all three attempts fail, that's a real outage or a deterministic
    # verification failure. Either way the install must NOT silently
    # succeed — the third attempt's failure has to propagate.
    last_attempt=$(awk '/Install slsa-verifier \(retry 2\)/,/^$/' "$ACTION_DIR/action.yml")
    [[ "$last_attempt" != *"continue-on-error"* ]]
}

@test "install_slsa_verifier: first two attempts have continue-on-error" {
    # Otherwise retry gating doesn't work — a step without
    # continue-on-error fails the whole composite immediately.
    coe_count=$(grep -c 'continue-on-error: true' "$ACTION_DIR/action.yml")
    [ "$coe_count" -eq 2 ]
}

@test "install_slsa_verifier: warning step gated on attempt-1-or-retry-1 failure" {
    # Alarm preservation: warn iff a retry was needed AND we ultimately
    # succeeded. Default `if: success()` handles the "ultimately
    # succeeded" half; this condition handles the "retry was needed"
    # half. Drift here weakens the supply-chain signal — see PR #260.
    run grep -E "if:.*install-slsa-verifier.outcome == 'failure'.*\|\|.*install-slsa-verifier-retry-1.outcome == 'failure'" "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "install_slsa_verifier: warning step emits a ::warning:: annotation" {
    run grep '::warning::slsa-verifier installer needed a retry' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
}

@test "install_slsa_verifier: each install attempt has an id (outcome observable)" {
    # Without ids, downstream steps in callers can't introspect which
    # attempt succeeded. Both retries get ids so a future caller can
    # decide policy based on which path recovered.
    run grep -cE 'id: install-slsa-verifier(-retry-[12])?$' "$ACTION_DIR/action.yml"
    [ "$status" -eq 0 ]
    [ "$output" -eq 3 ]
}
