# syntax=docker/dockerfile:1
# Wrangle osv-scanner tool image. Builds osv-scanner from the pinned
# tools/go.mod (manifest-preserving — keeps vuln scanning of its deps) and
# runs the existing wrangle osv adapter as the contract entrypoint:
#   docker run <image> <src> <output>  ->  <output>/output.sarif, exit 0/1/2
# Build context is the repo root (the build needs tools/go.mod + lib/).
FROM golang:1.26.4@sha256:32c0e6e5c4f6707717051091b4d0b077464a679eaab563e11474efc5328e2aa5 AS build
WORKDIR /src
COPY tools/ ./tools/
RUN cd tools && CGO_ENABLED=0 go build -trimpath \
      -o /out/osv-scanner github.com/google/osv-scanner/v2/cmd/osv-scanner

FROM debian:12-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -u 1000 -m wrangle
COPY --from=build /out/osv-scanner /usr/local/bin/osv-scanner
# Preserve the tools/osv + lib layout the adapter expects
# (adapter.sh -> render_md.sh -> ../../lib/sanitize.sh).
COPY tools/osv/adapter.sh tools/osv/render_md.sh /wrangle/tools/osv/
COPY lib/sanitize.sh /wrangle/lib/sanitize.sh
ENV HOME=/tmp
USER wrangle
ENTRYPOINT ["/wrangle/tools/osv/adapter.sh"]
