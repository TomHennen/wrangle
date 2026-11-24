# syntax=docker/dockerfile:1
# Wrangle wrangle-lint tool image. Builds the first-party wrangle-lint binary
# from the pinned tools/go.mod (manifest-preserving — keeps vuln scanning of its
# deps) and runs its adapter as the contract entrypoint:
#   docker run <image> <src> <output>  ->  <output>/output.sarif, exit 0/1/2
# Build context is the repo root (the build needs tools/go.mod + tools/wrangle-lint + lib/).
FROM golang:1.27.4@sha256:5f1b98fa02fe396ebce2a0227a0e08309e11792915b9dd2e1f71053d7e7e6666 AS build
WORKDIR /src
COPY tools/ ./tools/
RUN cd tools && CGO_ENABLED=0 go build -trimpath \
      -o /out/wrangle-lint github.com/TomHennen/wrangle/tools/wrangle-lint

# Minimal hardened base (Chainguard wolfi); the adapter entrypoint needs a
# shell + jq, which distroless lacks.
FROM cgr.dev/chainguard/wolfi-base@sha256:1d95114038f76513a9ace6fca107d5582b08c65981f81f61cb56bf7fd2ef216d
RUN apk add --no-cache bash jq ca-certificates \
 && adduser -D -u 1000 wrangle
COPY --from=build /out/wrangle-lint /usr/local/bin/wrangle-lint
COPY tools/wrangle-lint/adapter.sh /wrangle/tools/wrangle-lint/adapter.sh
COPY lib/sarif_adapter_exit.sh /wrangle/lib/sarif_adapter_exit.sh
ENV HOME=/tmp
USER wrangle
ENTRYPOINT ["/wrangle/tools/wrangle-lint/adapter.sh"]
