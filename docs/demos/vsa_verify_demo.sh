#!/usr/bin/env bash
set -euo pipefail
set -f
# Illustrative staged output for assets/vsa_verification.tape; not a real verifier.

g=$'\033[32m'; d=$'\033[2m'; b=$'\033[1m'; r=$'\033[0m'
rule='────────────────────────────────────────────────────────'

step() { printf '  %b[✓]%b %s\n' "$g" "$r" "$1"; sleep 0.45; }

printf '%b⏳ Loading attestation bundle  hello-world_1.2.0_linux_amd64.tar.gz.intoto.jsonl%b\n' "$d" "$r"
sleep 1.2
printf '%b⏳ Resolving policy  wrangle-vsa-consumer-v1  (git+github.com/TomHennen/wrangle@v0.2.2)%b\n' "$d" "$r"
sleep 1.3
printf '\n%bEvaluating wrangle-vsa-consumer-v1 against 1 subject%b\n\n' "$b" "$r"
sleep 0.5

step "DSSE signature verified  (Sigstore / Fulcio)"
step "Signer identity  TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@refs/tags/v0.2.2"
step "Build repository  github.com/acme/hello-world"
step "Subject digest matches  sha256:3f1c…9ab2"
step "Resource URI  pkg:golang/github.com/acme/hello-world@v1.2.0"
step "SLSA Build Level 3"
sleep 0.4

printf '\n  %b%s%b\n' "$d" "$rule" "$r"
printf '   VSA verdict      %b%bPASSED%b\n' "$g" "$b" "$r"
printf '   Subject          hello-world_1.2.0_linux_amd64.tar.gz\n'
printf '   Verified level   SLSA_BUILD_LEVEL_3\n'
printf '   Policy           wrangle-vsa-consumer-v1\n'
printf '  %b%s%b\n' "$d" "$rule" "$r"
sleep 0.6
printf '\n%b✔ Verification successful%b — these bytes carry a signed, PASSED wrangle VSA.\n' "$g" "$r"
