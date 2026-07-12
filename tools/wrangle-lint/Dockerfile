# syntax=docker/dockerfile:1
# Wrangle wrangle-lint tool image. Builds the first-party wrangle-lint binary
# from the pinned tools/go.mod (manifest-preserving — keeps vuln scanning of its
# deps) and runs its adapter as the contract entrypoint:
#   docker run <image> <src> <output>  ->  <output>/output.sarif, exit 0/1/2
# Build context is the repo root (the build needs tools/go.mod + tools/wrangle-lint + lib/).
FROM golang:1.26.4@sha256:32c0e6e5c4f6707717051091b4d0b077464a679eaab563e11474efc5328e2aa5 AS build
WORKDIR /src
COPY tools/go.mod tools/go.sum ./tools/
COPY tools/wrangle-lint/ ./tools/wrangle-lint/
RUN cd tools && CGO_ENABLED=0 go build -trimpath \
      -o /out/wrangle-lint github.com/TomHennen/wrangle/tools/wrangle-lint

# Minimal hardened base (Chainguard wolfi); the adapter entrypoint needs a
# shell + jq, which distroless lacks.
FROM cgr.dev/chainguard/wolfi-base@sha256:0b613d8101fae27cf76186351db831ab3db25bfb2ec7161e897cd7e22c6413a3
RUN apk add --no-cache bash jq ca-certificates \
 && adduser -D -u 1000 wrangle
COPY --from=build /out/wrangle-lint /usr/local/bin/wrangle-lint
COPY tools/wrangle-lint/adapter.sh /wrangle/tools/wrangle-lint/adapter.sh
COPY lib/sarif_adapter_exit.sh /wrangle/lib/sarif_adapter_exit.sh
ENV HOME=/tmp
USER wrangle
ENTRYPOINT ["/wrangle/tools/wrangle-lint/adapter.sh"]
