FROM ubuntu:24.04@sha256:186072bba1b2f436cbb91ef2567abca677337cfc786c86e107d25b7072feef0c

RUN apt-get update -q && \
    apt-get install -y -q --no-install-recommends \
        bats \
        curl \
        git \
        jq \
        shellcheck \
        ca-certificates \
        make \
        gcc \
        libc6-dev \
        python3 \
        python3-venv \
        python3-yaml \
    && rm -rf /var/lib/apt/lists/*

# python3 + python3-venv host the isolated venvs that both zizmor and
# ast-grep install into (each tool gets its own venv via tools/<tool>/
# requirements.txt with --require-hashes). See pypa/pipx#712 for why
# pipx + --require-hashes isn't viable.
#
# python3-yaml (PyYAML) backs tools/wrangle-workflow-lint/lint.py. It's a
# pure-Python parser shipped by the Ubuntu base repo, so it rides the same
# apt trust model as the python3 interpreter itself — no separate
# hash-pinned venv (a library import for an internal script is not a
# wrapped third-party tool like zizmor / ast-grep). See DEP_MGMT.md.

# gcc + libc6-dev are pulled in for `go test -race` (cgo needs a C toolchain).

SHELL ["/bin/bash", "-c"]

# Install actionlint — pinned version with checksum verification
ARG ACTIONLINT_VERSION=1.7.12
ARG ACTIONLINT_CHECKSUM_ARM64=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
ARG ACTIONLINT_CHECKSUM_AMD64=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
RUN set -euo pipefail && \
    ARCH="$(uname -m)" && \
    case "$ARCH" in \
        aarch64) GOARCH=arm64; EXPECTED_CHECKSUM="$ACTIONLINT_CHECKSUM_ARM64" ;; \
        x86_64)  GOARCH=amd64; EXPECTED_CHECKSUM="$ACTIONLINT_CHECKSUM_AMD64" ;; \
        *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac && \
    TARBALL="actionlint_${ACTIONLINT_VERSION}_linux_${GOARCH}.tar.gz" && \
    curl --fail -sSL -o "/tmp/$TARBALL" \
        "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${TARBALL}" && \
    echo "$EXPECTED_CHECKSUM  /tmp/$TARBALL" | sha256sum -c - && \
    tar -xzf "/tmp/$TARBALL" -C /usr/local/bin actionlint && \
    rm "/tmp/$TARBALL"

# Install Go — pinned version with checksum verification. Used by
# build/actions/go/test.bats layer-3 integration tests (real gofmt,
# go vet, go test, govulncheck against fixtures). Other build types'
# tests don't need Go; cost is ~80MB on the image but avoids the
# cross-repo wrangle-test dispatch loop for catching regressions in
# run_checks.sh and friends.
ARG GO_VERSION=1.26.3
ARG GO_CHECKSUM_ARM64=9d89a3ea57d141c2b22d70083f2c8459ba3890f2d9e818e7e933b75614936565
ARG GO_CHECKSUM_AMD64=2b2cfc7148493da5e73981bffbf3353af381d5f93e789c82c79aff64962eb556
RUN set -euo pipefail && \
    ARCH="$(uname -m)" && \
    case "$ARCH" in \
        aarch64) GOARCH=arm64; EXPECTED_CHECKSUM="$GO_CHECKSUM_ARM64" ;; \
        x86_64)  GOARCH=amd64; EXPECTED_CHECKSUM="$GO_CHECKSUM_AMD64" ;; \
        *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac && \
    TARBALL="go${GO_VERSION}.linux-${GOARCH}.tar.gz" && \
    curl --fail -sSL -o "/tmp/$TARBALL" \
        "https://go.dev/dl/${TARBALL}" && \
    echo "$EXPECTED_CHECKSUM  /tmp/$TARBALL" | sha256sum -c - && \
    tar -xzf "/tmp/$TARBALL" -C /usr/local && \
    rm "/tmp/$TARBALL"
ENV PATH="/usr/local/go/bin:${PATH}"

# Install govulncheck — same pinned version as build/actions/go/checks/
# action.yml's default. Pre-installed in the image so layer-3 tests
# don't pay the `go install` cost on every test run. Lives under a
# shared GOPATH so the test's `install_govulncheck` idempotency check
# hits the cache.
ENV GOPATH=/opt/go
ENV PATH="/opt/go/bin:${PATH}"
ARG GOVULNCHECK_VERSION=v1.1.4
RUN set -euo pipefail && \
    mkdir -p /opt/go && \
    go install "golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}"

# zizmor — hash-pinned via tools/zizmor/requirements.txt; Dependabot bumps
# version + hashes atomically.
COPY tools/zizmor/requirements.txt /tmp/zizmor-requirements.txt
RUN set -euo pipefail && \
    python3 -m venv /opt/zizmor-venv && \
    /opt/zizmor-venv/bin/pip install --no-cache-dir \
        --require-hashes -r /tmp/zizmor-requirements.txt && \
    ln -s /opt/zizmor-venv/bin/zizmor /usr/local/bin/zizmor && \
    rm /tmp/zizmor-requirements.txt

# ast-grep-cli — same pattern (hash-pinned via tools/wrangle-shell-lint/requirements.txt).
COPY tools/wrangle-shell-lint/requirements.txt /tmp/ast-grep-requirements.txt
RUN set -euo pipefail && \
    python3 -m venv /opt/ast-grep && \
    /opt/ast-grep/bin/pip install --no-cache-dir \
        --require-hashes -r /tmp/ast-grep-requirements.txt && \
    ln -s /opt/ast-grep/bin/ast-grep /usr/local/bin/ast-grep && \
    rm /tmp/ast-grep-requirements.txt

WORKDIR /wrangle
