FROM ubuntu:24.04

RUN apt-get update -q && \
    apt-get install -y -q --no-install-recommends \
        bats \
        curl \
        jq \
        shellcheck \
        ca-certificates \
        make \
    && rm -rf /var/lib/apt/lists/*

# Install actionlint
RUN curl -sSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash | bash -s -- latest /usr/local/bin

WORKDIR /wrangle
