# syntax=docker/dockerfile:1
# Wrangle syft tool image (sbom kind): docker run <image> <src> <output> ->
# <output>/sbom.<fmt>.json, exit 0/2. The build stage runs install.sh's
# cosign-keyless verify chain and copies the verified binary onto the runtime —
# shipped verified rather than rebuilt because no package manager ships syft's
# adapter and Anchore's image is unsigned (tool_container_design.md §3.4).
# Build context is the repo root (needs tools/syft + lib/).
FROM cgr.dev/chainguard/wolfi-base@sha256:03c6561658909fc4eadd0b2dc717375df40a22cc05455b8f82f1f1974e7e4427 AS build
# install.sh needs cosign + curl + coreutils + gawk; tar is a busybox applet.
RUN apk add --no-cache bash curl cosign coreutils gawk
COPY lib/download_verify.sh /build/lib/download_verify.sh
COPY tools/syft/install.sh /build/tools/syft/install.sh
RUN WRANGLE_BIN_DIR=/out /build/tools/syft/install.sh

# Minimal hardened base; the adapter entrypoint needs a shell + jq.
FROM cgr.dev/chainguard/wolfi-base@sha256:03c6561658909fc4eadd0b2dc717375df40a22cc05455b8f82f1f1974e7e4427
RUN apk add --no-cache bash jq ca-certificates \
 && adduser -D -u 1000 wrangle
COPY --from=build /out/syft /usr/local/bin/syft
COPY tools/syft/adapter.sh /wrangle/tools/syft/adapter.sh
# Arbitrary -u uid has no /etc/passwd entry; HOME must be a writable path.
ENV HOME=/tmp
USER wrangle
ENTRYPOINT ["/wrangle/tools/syft/adapter.sh"]
