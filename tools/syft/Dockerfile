# syntax=docker/dockerfile:1
# Wrangle syft tool image (sbom kind). Option (c): the build stage runs the same
# cosign-keyless verify chain as tools/syft/install.sh — download checksums.txt +
# its Sigstore signature/cert, `cosign verify-blob` against anchore/syft's
# release workflow identity, then SHA-verify the binary against the now-trusted
# checksums — and copies the verified binary onto a minimal runtime that runs the
# wrangle syft adapter as the contract entrypoint:
#   docker run <image> <src> <output>  ->  <output>/sbom.<fmt>.json, exit 0/2
# No Go module ships syft's adapter and Anchore's own image is unsigned, so the
# binary is shipped verified rather than rebuilt (docs/tool_container_design.md
# §3.4 divergence). Build context is the repo root (needs tools/syft + lib/).
FROM cgr.dev/chainguard/wolfi-base@sha256:0b613d8101fae27cf76186351db831ab3db25bfb2ec7161e897cd7e22c6413a3 AS build
# cosign verifies the checksums signature; curl/coreutils/gawk are what
# install.sh + lib/download_verify.sh use to fetch and SHA-check the binary
# (tar, for extraction, is a busybox applet in the base).
RUN apk add --no-cache bash curl cosign coreutils gawk
COPY lib/download_verify.sh /build/lib/download_verify.sh
COPY tools/syft/install.sh /build/tools/syft/install.sh
# install.sh fetches the pinned syft, cosign-verifies it, and writes the binary
# to WRANGLE_BIN_DIR; aborts (no fallback) if verification fails.
RUN WRANGLE_BIN_DIR=/out /build/tools/syft/install.sh

# Minimal hardened base; the adapter entrypoint needs a shell + jq.
FROM cgr.dev/chainguard/wolfi-base@sha256:0b613d8101fae27cf76186351db831ab3db25bfb2ec7161e897cd7e22c6413a3
RUN apk add --no-cache bash jq ca-certificates \
 && adduser -D -u 1000 wrangle
COPY --from=build /out/syft /usr/local/bin/syft
COPY tools/syft/adapter.sh /wrangle/tools/syft/adapter.sh
ENV HOME=/tmp
USER wrangle
ENTRYPOINT ["/wrangle/tools/syft/adapter.sh"]
