#!/usr/bin/env bats

# Structure guard for actions/verify's tool install. verify runs ampel (verify)
# and bnd (sign) always, and cosign (push the VSA referrer) only for the
# container build — never the whole `tool` set, whose scan binaries (osv-scanner
# et al.) it does not run. The action delegates to install_tools.sh; this checks
# the wiring and that each installed package is a pinned tool directive.

setup() {
    DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    ACTION="$DIR/action.yml"
    INSTALL="$DIR/install_tools.sh"
    GOMOD="$(cd "$DIR/../.." && pwd)/tools/go.mod"
    export DIR ACTION INSTALL GOMOD
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

@test "install_tools.sh installs ampel, bnd, cosign — each pinned in tools/go.mod" {
    local p
    for p in \
        github.com/carabiner-dev/ampel/cmd/ampel \
        github.com/carabiner-dev/bnd \
        github.com/sigstore/cosign/v3/cmd/cosign
    do
        grep -Fq "$p" "$INSTALL"
        tool_block_has "$p"
    done
}

@test "install_tools.sh gates cosign on OCI_TARGET" {
    # cosign must sit inside an OCI_TARGET conditional, not the unconditional set.
    grep -Eq 'OCI_TARGET' "$INSTALL"
    grep -Eq 'if \[\[ -n "\$\{OCI_TARGET:-\}" \]\]' "$INSTALL"
}

@test "action.yml delegates to install_tools.sh and threads OCI_TARGET via env" {
    grep -q 'install_tools.sh' "$ACTION"
    grep -q 'OCI_TARGET: ${{ inputs.oci-target }}' "$ACTION"
}

@test "attach step is gated on both attach-to-release and attach-release-assets and threads the asset env" {
    grep -Fq "inputs.attach-to-release == 'true' && inputs.attach-release-assets == 'true'" "$ACTION"
    grep -Fq 'BUILD_TYPE: ${{ inputs.build-type }}' "$ACTION"
    grep -Fq 'DIST_DIR: ${{ inputs.dist-dir }}' "$ACTION"
    grep -Fq 'METADATA_ZIP_NAME: ${{ inputs.artifact-name }}.zip' "$ACTION"
}

@test "verify does not build the whole tool set or the scan-only binaries" {
    # `go install tool` would rebuild osv-scanner et al. that verify never runs.
    ! grep -Eq 'install[[:space:]]+tool([[:space:]]|$)' "$ACTION"
    local f
    for f in "$ACTION" "$INSTALL"; do
        ! grep -Fq 'osv-scanner' "$f"
        ! grep -Fq 'cmd/govulncheck' "$f"
        ! grep -Fq 'tools/wrangle-lint' "$f"
    done
}
