# syntax=docker/dockerfile:1
# Wrangle syft tool image (sbom kind): docker run <image> <src> <output> ->
# <output>/sbom.<fmt>.json, exit 0/2. The build stage runs install.sh's
# cosign-keyless verify chain and copies the verified binary onto the runtime —
# shipped verified rather than rebuilt because no package manager ships syft's
# adapter and Anchore's image is unsigned (tool_container_design.md §3.4).
# Build context is the repo root (needs tools/syft + lib/).
FROM cgr.dev/chainguard/wolfi-base@sha256:1d95114038f76513a9ace6fca107d5582b08c65981f81f61cb56bf7fd2ef216d AS build
# install.sh needs cosign + curl + coreutils + gawk; tar is a busybox applet.
RUN apk add --no-cache bash curl cosign coreutils gawk
COPY lib/download_verify.sh /build/lib/download_verify.sh
COPY tools/syft/install.sh /build/tools/syft/install.sh
RUN WRANGLE_BIN_DIR=/out /build/tools/syft/install.sh

# Minimal hardened base; the adapter entrypoint needs a shell + jq.
FROM cgr.dev/chainguard/wolfi-base@sha256:1d95114038f76513a9ace6fca107d5582b08c65981f81f61cb56bf7fd2ef216d
RUN apk add --no-cache bash jq ca-certificates \
 && adduser -D -u 1000 wrangle
COPY --from=build /out/syft /usr/local/bin/syft
COPY tools/syft/adapter.sh /wrangle/tools/syft/adapter.sh
# Arbitrary -u uid has no /etc/passwd entry; HOME must be a writable path.
ENV HOME=/tmp
USER wrangle
ENTRYPOINT ["/wrangle/tools/syft/adapter.sh"]
