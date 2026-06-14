#!/usr/bin/env bats

# Structure guard for actions/verify/action.yml's tool install. verify runs
# ampel (verify), bnd (sign), and cosign (push the VSA referrer), so it builds
# exactly those from the pinned manifest — never the whole `tool` set, whose
# scan binaries (osv-scanner et al.) it does not run. Each package must be a
# pinned tool directive so `go install <pkg>` resolves.

setup() {
    ACTION="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/action.yml"
    GOMOD="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/tools/go.mod"
    export ACTION GOMOD
}

# Does tools/go.mod's `tool` block pin the given package path?
tool_block_has() {
    awk '
        /^tool[[:space:]]*\(/ {inblock=1; next}
        inblock && /^\)/      {inblock=0; next}
        inblock               {gsub(/[[:space:]]/,""); if ($0!="") print; next}
        /^tool[[:space:]]+[^(]/ {print $2}
    ' "$GOMOD" | grep -Fxq "$1"
}

@test "verify installs ampel, bnd, cosign — each pinned in tools/go.mod" {
    local p
    for p in \
        github.com/carabiner-dev/ampel/cmd/ampel \
        github.com/carabiner-dev/bnd \
        github.com/sigstore/cosign/v3/cmd/cosign
    do
        grep -Fq "$p" "$ACTION"
        tool_block_has "$p"
    done
}

@test "verify does not build the whole tool set or the scan-only binaries" {
    # `go install tool` would rebuild osv-scanner et al. that verify never runs.
    ! grep -Eq 'install[[:space:]]+tool([[:space:]]|$)' "$ACTION"
    ! grep -Fq 'osv-scanner' "$ACTION"
    ! grep -Fq 'cmd/govulncheck' "$ACTION"
    ! grep -Fq 'tools/wrangle-lint' "$ACTION"
}
