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
    && rm -rf /var/lib/apt/lists/*

# gcc + libc6-dev are pulled in for `go test -race` (the race detector
# requires cgo, which requires a C toolchain). Without them, Go's
# layer-4 tests that exercise -race fail with cryptic linker errors.
# This matches GHA's ubuntu-latest image, which has gcc by default.

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
    curl -sSL -o "/tmp/$TARBALL" \
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
    curl -sSL -o "/tmp/$TARBALL" \
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

# Install zizmor — pinned version with checksum verification. Used by
# `make zizmor` (and the default `./test.sh`) so wrangle's own workflow
# security findings surface locally, not just in CI. Version is kept in
# sync with tools/zizmor/action.yml's default input. Upstream ships
# GitHub build attestations (actions/attest); we use pinned sha256 here
# to match actionlint's pattern and avoid pulling gh/cosign into the
# image just for one tool.
ARG ZIZMOR_VERSION=1.23.1
ARG ZIZMOR_CHECKSUM_ARM64=3725d7cd7102e4d70827186389f7d5930b6878232930d0a3eb058d7e5b47e658
ARG ZIZMOR_CHECKSUM_AMD64=67a8df0a14352dd81882e14876653d097b99b0f4f6b6fe798edc0320cff27aff
RUN set -euo pipefail && \
    ARCH="$(uname -m)" && \
    case "$ARCH" in \
        aarch64) TRIPLE=aarch64-unknown-linux-gnu; EXPECTED_CHECKSUM="$ZIZMOR_CHECKSUM_ARM64" ;; \
        x86_64)  TRIPLE=x86_64-unknown-linux-gnu;  EXPECTED_CHECKSUM="$ZIZMOR_CHECKSUM_AMD64" ;; \
        *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac && \
    TARBALL="zizmor-${TRIPLE}.tar.gz" && \
    curl -sSL -o "/tmp/$TARBALL" \
        "https://github.com/zizmorcore/zizmor/releases/download/v${ZIZMOR_VERSION}/${TARBALL}" && \
    echo "$EXPECTED_CHECKSUM  /tmp/$TARBALL" | sha256sum -c - && \
    tar -xzf "/tmp/$TARBALL" -C /usr/local/bin ./zizmor && \
    rm "/tmp/$TARBALL"

WORKDIR /wrangle
