#!/bin/bash
set -euo pipefail
set -f

# Install the tools wrangle's integration bats suites need on top of the
# shell build type's own installs (shellcheck, bats): the Go tools from
# tools/go.mod (ampel, bnd, cosign, osv-scanner — go.sum integrity,
# Dependabot freshness). Single source of truth for those deps: consumed
# as the setup-script input of wrangle's own build_shell.yml call AND by
# `make integration` inside the test container (`./test.sh integration`).
#
# Requires go and jq on PATH (GitHub runner images and test/Dockerfile
# both provide them). Installs into $WRANGLE_BIN_DIR (lib/env.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/env.sh
source "$REPO_ROOT/lib/env.sh"

mkdir -p "$WRANGLE_BIN_DIR"

for tool in go jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'setup_integration: %s not on PATH (required)\n' "$tool" >&2
        exit 1
    fi
done

# All Go tools (ampel, bnd, cosign, osv-scanner, govulncheck) come from
# tools/go.mod's tool directives; env.sh pins GOPROXY/GOSUMDB so the sum
# database can't be disabled. go requires an absolute GOBIN, and env.sh's
# local default for WRANGLE_BIN_DIR is CWD-relative.
#
# The stamp records the go.sum the binaries were built for: a warm bin dir
# (a restored CI cache) with a matching stamp skips the rebuild, and a go.sum
# change forces a fresh install so a stale cache can't serve mismatched tools.
TOOLS_STAMP="$WRANGLE_BIN_DIR/.go-tools.stamp"
GOSUM_DIGEST="$(sha256sum "$REPO_ROOT/tools/go.sum" | cut -d' ' -f1)"
if [[ -f "$TOOLS_STAMP" && "$(<"$TOOLS_STAMP")" == "$GOSUM_DIGEST" ]]; then
    printf 'setup_integration: Go tools present for current go.sum, skipping install\n'
else
    GOBIN="$(cd "$WRANGLE_BIN_DIR" && pwd)" go -C "$REPO_ROOT/tools" install tool
    printf '%s\n' "$GOSUM_DIGEST" > "$TOOLS_STAMP"
fi

# The lint-tool venvs the unit bats exercise (wrangle-shell-lint needs
# ast-grep; wrangle-workflow-lint runs lint.py under a python that can
# import yaml). Same hash-pinned requirements.txt installs as
# test/Dockerfile; ast-grep's entrypoint lands on PATH via WRANGLE_BIN_DIR.
if ! command -v ast-grep >/dev/null 2>&1; then
    python3 -m venv /tmp/wrangle-venvs/ast-grep
    /tmp/wrangle-venvs/ast-grep/bin/pip install --quiet --no-cache-dir \
        --require-hashes -r "$REPO_ROOT/tools/wrangle-shell-lint/requirements.txt"
    ln -sf /tmp/wrangle-venvs/ast-grep/bin/ast-grep "$WRANGLE_BIN_DIR/ast-grep"
fi

# zizmor for the detection canary (tools/zizmor/test.bats) and the
# example-workflow scan (test/test_examples_scan.bats). Same hash-pinned
# requirements.txt the test container installs; entrypoint onto PATH via
# WRANGLE_BIN_DIR. Without it those bats skip_or_fail (FATAL) under CI.
if ! command -v zizmor >/dev/null 2>&1; then
    python3 -m venv /tmp/wrangle-venvs/zizmor
    /tmp/wrangle-venvs/zizmor/bin/pip install --quiet --no-cache-dir \
        --require-hashes -r "$REPO_ROOT/tools/zizmor/requirements.txt"
    ln -sf /tmp/wrangle-venvs/zizmor/bin/zizmor "$WRANGLE_BIN_DIR/zizmor"
fi

# wrangle-workflow-lint's lint.sh prefers this exact venv path (PyYAML is
# a library — no entrypoint to put on PATH). Root (the test container)
# writes /opt directly; the GitHub runner needs sudo.
WWL_VENV="/opt/wrangle-workflow-lint"
if ! "$WWL_VENV/bin/python3" -c 'import yaml' >/dev/null 2>&1; then
    if [[ -w /opt ]]; then
        python3 -m venv "$WWL_VENV"
        "$WWL_VENV/bin/pip" install --quiet --no-cache-dir \
            --require-hashes -r "$REPO_ROOT/tools/wrangle-workflow-lint/requirements.txt"
    else
        sudo python3 -m venv "$WWL_VENV"
        sudo "$WWL_VENV/bin/pip" install --quiet --no-cache-dir \
            --require-hashes -r "$REPO_ROOT/tools/wrangle-workflow-lint/requirements.txt"
    fi
fi

# Warm the docker layer cache for the curated tool images concurrently, so the
# image bats' per-file builds hit the cache instead of recompiling from source.
"$SCRIPT_DIR/prebuild_tool_images.sh"

# Later workflow steps (the shell build's bats step) run in fresh shells;
# the env.sh PATH export above only covers this process.
if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$WRANGLE_BIN_DIR" >> "$GITHUB_PATH"
fi

printf 'setup_integration: installed tool versions:\n'
osv-scanner --version | head -1
ampel version | head -1
cosign version 2>&1 | grep GitVersion
zizmor --version | head -1
