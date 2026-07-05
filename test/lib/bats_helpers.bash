# test/lib/bats_helpers.bash — shared bats helpers, pulled in with `load`.
# A sourced helper library: no shebang (it's loaded into a bats test, never
# executed on its own), so it carries no script preamble. Not a *.bats file, so
# the suite's glob doesn't run it as a test.

# in_ci: true under CI (CI/GITHUB_ACTIONS set). The single definition of
# "are we in CI" for test helpers — skip policy and preflight probes must
# agree on it.
in_ci() {
    [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]
}

# skip_or_fail <reason>: under CI the real binary + network are present, so a
# skip means the test silently degraded — fail instead. Locally skip, so
# sandboxed dev isn't blocked.
skip_or_fail() {
    if in_ci; then
        printf 'FATAL: %s (skip not allowed in CI)\n' "$1" >&2
        exit 1
    fi
    skip "$1"
}

# A digest-pinned curated toolbox image used across the signer tests.
WRANGLE_TEST_TOOLBOX_IMAGE="ghcr.io/tomhennen/wrangle/attest-toolbox@sha256:0000000000000000000000000000000000000000000000000000000000000000"

# wrangle_stub_toolbox_transparent [dir]: make the always-containerized signer
# path transparent for orchestration tests — the token grant is present, the VSA
# gate passes, the mint succeeds, and `docker run … -- <image> <tool> <args>`
# execs `<tool> <args>` on the host (host==container paths), so a test's in-PATH
# tool stub runs and its arg/IO assertions hold. Tests that inspect the docker
# argv or exercise fail-closed paths install their own recording docker stub +
# catalog, which override this.
wrangle_stub_toolbox_transparent() {
    local dir="${1:-$TEST_DIR}"
    cat > "$dir/docker" <<'EOF'
#!/bin/bash
# Exec the in-container command: everything after `-- <image>`.
args=("$@")
i=0
while [[ $i -lt ${#args[@]} && "${args[$i]}" != "--" ]]; do i=$((i + 1)); done
exec "${args[@]:$((i + 2))}"
EOF
    cat > "$dir/gh" <<EOF
#!/bin/bash
cat <<JSON
[{"verificationResult":{"statement":{"predicate":{"verificationResult":"PASSED","resourceUri":"$WRANGLE_TEST_TOOLBOX_IMAGE","verifiedLevels":["SLSA_BUILD_LEVEL_3"]}}}}]
JSON
EOF
    cat > "$dir/curl" <<'EOF'
#!/bin/bash
printf '{"value":"MINTED-SIGSTORE-JWT"}\n'
EOF
    chmod +x "$dir/docker" "$dir/gh" "$dir/curl"
    cat > "$dir/catalog.json" <<EOF
{"tools":{"attest-toolbox":{"kind":"attest","image":"$WRANGLE_TEST_TOOLBOX_IMAGE","network":"egress","token":"sigstore"}}}
EOF
    export PATH="$dir:$PATH"
    export WRANGLE_CATALOG="$dir/catalog.json"
    export ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.example/token"
    export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-bearer-secret"
    export GITHUB_TOKEN="${GITHUB_TOKEN:-registry-token}"
}
