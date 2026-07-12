# syntax=docker/dockerfile:1
# Wrangle zizmor tool image. Installs zizmor from the hash-pinned
# tools/zizmor/requirements.txt (pip --require-hashes, the canonical PyPI
# distribution — keeps the dependency manifest in-repo for Dependabot/osv) and
# runs the wrangle zizmor adapter as the contract entrypoint:
#   docker run <image> <src> <output>  ->  <output>/output.sarif, exit 0/1/2
# Build context is the repo root (the build needs tools/zizmor/ + lib/).
FROM cgr.dev/chainguard/wolfi-base@sha256:0b613d8101fae27cf76186351db831ab3db25bfb2ec7161e897cd7e22c6413a3 AS build
RUN apk add --no-cache python-3.13 py3.13-pip
COPY tools/zizmor/requirements.txt /tmp/requirements.txt
# Hermetic, hash-verified install into a self-contained prefix copied below.
RUN python3 -m pip install --require-hashes --no-deps \
      --prefix=/opt/zizmor -r /tmp/requirements.txt

# Minimal hardened base; the adapter entrypoint needs a shell + jq, and zizmor
# (a Rust binary wheel) needs the Python runtime its console script launches.
FROM cgr.dev/chainguard/wolfi-base@sha256:0b613d8101fae27cf76186351db831ab3db25bfb2ec7161e897cd7e22c6413a3
RUN apk add --no-cache bash jq ca-certificates python-3.13 \
 && adduser -D -u 1000 wrangle
COPY --from=build /opt/zizmor /opt/zizmor
COPY tools/zizmor/adapter.sh /wrangle/tools/zizmor/adapter.sh
COPY lib/sarif_adapter_exit.sh /wrangle/lib/sarif_adapter_exit.sh
ENV PATH="/opt/zizmor/bin:${PATH}" \
    PYTHONPATH="/opt/zizmor/lib/python3.13/site-packages" \
    HOME=/tmp
USER wrangle
ENTRYPOINT ["/wrangle/tools/zizmor/adapter.sh"]
