# syntax=docker/dockerfile:1
# Wrangle attest/verify toolbox image. Builds the four signing-path binaries
# from the pinned tools/go.mod (manifest-preserving — keeps vuln scanning of
# their deps) onto a hardened wolfi base, all four on PATH:
#   ampel          — evaluate a release against a PolicySet, emit the VSA
#   bnd            — keyless-sign statements (provenance, SBOM, VSA)
#   cosign         — push attestations as OCI referrers
#   wrangle-attest — build the unsigned scan/build in-toto statements
# Unlike the scan-tool images this is NOT a sandboxed adapter: the verify/attest
# path needs network egress (Sigstore/Rekor, the GitHub attestation store, the
# registry) and, when signing, the workflow's OIDC token. It therefore ships no
# adapter ENTRYPOINT — the orchestrator invokes a specific binary with its own
# args. The egress + token surface is the reason §7 of docs/tool_container_design.md
# flags this path as higher-stakes than the scan images.
# Build context is the repo root (the build needs tools/go.mod + go.sum).
FROM golang:1.26.4@sha256:32c0e6e5c4f6707717051091b4d0b077464a679eaab563e11474efc5328e2aa5 AS build
WORKDIR /src
COPY tools/ ./tools/
ENV CGO_ENABLED=0
RUN cd tools \
 && go build -trimpath -o /out/ampel github.com/carabiner-dev/ampel/cmd/ampel \
 && go build -trimpath -o /out/bnd github.com/carabiner-dev/bnd \
 && go build -trimpath -o /out/cosign github.com/sigstore/cosign/v3/cmd/cosign \
 && go build -trimpath -o /out/wrangle-attest github.com/TomHennen/wrangle/tools/wrangle-attest

# Minimal hardened base (Chainguard wolfi). ca-certificates is required: every
# binary here makes outbound TLS calls (Sigstore, Rekor, the attestation store,
# the registry). jq is bundled because the verify/attest glue normalizes the
# tools' JSON output; bash for any wrapper invocation.
FROM cgr.dev/chainguard/wolfi-base@sha256:0b613d8101fae27cf76186351db831ab3db25bfb2ec7161e897cd7e22c6413a3
RUN apk add --no-cache bash jq ca-certificates \
 && adduser -D -u 1000 wrangle
COPY --from=build /out/ampel /out/bnd /out/cosign /out/wrangle-attest /usr/local/bin/
ENV HOME=/tmp
USER wrangle
