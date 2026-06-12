# Verifying wrangle-built artifacts

Wrangle produces two attestations for every released artifact:

- **SLSA Build L3 provenance** — *how the artifact was built*: the builder, the
  source commit, the workflow. Produced by `actions/attest-build-provenance`
  inside wrangle's isolated reusable workflow and stored in GitHub's
  attestation store for the adopter's repo.
- **A SLSA Verification Summary Attestation (VSA)** — *the policy verdict*:
  a signed record that the artifact passed wrangle's policy at SLSA
  Build L3. Keyless-signed by **wrangle's** reusable workflow (not the
  adopter's). For Go, Python, and npm builds the VSA is attached to the
  GitHub release as `<artifact>.intoto.jsonl`; for container images it is
  stored in the registry as an OCI referrer on the image digest (containers
  produce no GitHub release).

A consumer's one-command check is the VSA: it carries the full verdict, so
you trust one signature instead of re-running the policy engine.

## What to plug in, per ecosystem

| Build type | VSA location | `resourceUri` to expect | Signing workflow |
|---|---|---|---|
| Go | GitHub release, `<archive>.intoto.jsonl` | `pkg:golang/<module-path>@<version>` (the `module` directive in `go.mod`) | `build_and_publish_go.yml` |
| Python | GitHub release, `<dist-file>.intoto.jsonl` (wheel or sdist) | `pkg:pypi/<name>@<version>` (name [PEP 503-normalized](https://peps.python.org/pep-0503/#normalized-names)) | `build_and_publish_python.yml` |
| npm | GitHub release, `<tarball>.intoto.jsonl` | `pkg:npm/<name>@<version>` (scoped names verbatim, e.g. `pkg:npm/@scope/pkg@1.2.3`) | `build_and_publish_npm.yml` |
| Container | OCI referrer on the image digest | `<imagename>@sha256:<digest>` | `build_and_publish_container.yml` |

## Recommended: `ampel verify` (one command)

[ampel](https://github.com/carabiner-dev/ampel) ≥ v1.3.0 (one Go binary)
checks everything that matters in a single command: these exact bytes are
what passed policy, wrangle signed the verdict, **your repo built the
artifact** (not a fork, not someone else's wrangle build), and the verdict
is PASSED at SLSA Build L3. The policy is wrangle-hosted and fetched by
locator, so you author nothing. Both `--context` values are required;
omitting one is a hard error, never a weaker check.

For file artifacts (Go / Python / npm), download the artifact and its VSA
from the release, then:

```bash
ampel verify --subject <artifact> \
  --policy git+https://github.com/TomHennen/wrangle@v0.2.0#policies/wrangle-vsa-consumer-v1.hjson \
  --attestation <artifact>.intoto.jsonl \
  --context expectedResourceUri:<resourceUri from the table above> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

For container images, ampel fetches the VSA from the registry itself — no
download step:

```bash
ampel verify --subject sha256:<digest> \
  --policy git+https://github.com/TomHennen/wrangle@v0.2.0#policies/wrangle-vsa-consumer-v1.hjson \
  --collector oci:<imagename>@sha256:<digest> \
  --context expectedResourceUri:<imagename>@sha256:<digest> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

Pin the policy locator to any wrangle `v*` release tag — it does **not**
need to match the wrangle version the adopter builds with. The `-v1` in the
policy filename is the contract version; any release tag carrying that file
verifies any wrangle-signed VSA.

## Without ampel: cosign + jq

cosign performs the same complete check, minus predicate-field reads — so a
`jq` decode covers `verificationResult` / `resourceUri` / `verifiedLevels`.

For file artifacts (`cosign verify-blob-attestation`):

```bash
cosign verify-blob-attestation --bundle <artifact>.intoto.jsonl --new-bundle-format \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_<type>\.yml@refs/tags/v' \
  --certificate-github-workflow-repository <your-org>/<your-repo> \
  --type https://slsa.dev/verification_summary/v1 \
  <artifact>

payload="$(jq -r '.dsseEnvelope.payload' <artifact>.intoto.jsonl | base64 -d)"
jq -e '.predicate.verificationResult == "PASSED"' <<<"$payload"
jq -e '.predicate.resourceUri == "<resourceUri from the table above>"' <<<"$payload"
jq -e '.predicate.verifiedLevels | index("SLSA_BUILD_LEVEL_3")' <<<"$payload"
```

Substitute `<type>` with `go`, `python`, or `npm`. The `@refs/tags/v` anchor
assumes the adopter pinned wrangle at a release tag (the examples' default);
adjust it if they pinned a SHA. `--type` must be the full URI — cosign
rejects the `slsaverificationsummary` alias.

For container images, a digest subject has no file blob, so the command is
`cosign verify-attestation` (cosign v3) against the image. It prints the
verified envelope to stdout, so capture and decode that:

```bash
cosign verify-attestation \
  --type https://slsa.dev/verification_summary/v1 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_container\.yml@refs/tags/v' \
  --certificate-github-workflow-repository <your-org>/<your-repo> \
  <imagename>@sha256:<digest> > vsa.json

payload="$(jq -r '.payload' vsa.json | base64 -d)"
jq -e '.subject[0].digest.sha256 == "<digest>"' <<<"$payload"
jq -e '.predicate.verificationResult == "PASSED"' <<<"$payload"
jq -e '.predicate.resourceUri == "<imagename>@sha256:<digest>"' <<<"$payload"
jq -e '.predicate.verifiedLevels | index("SLSA_BUILD_LEVEL_3")' <<<"$payload"
```

> **`slsa-verifier verify-vsa` is not usable here.** It only verifies
> *key-signed* VSAs (it requires `--public-key-path`); wrangle's VSAs are
> keyless (Fulcio/Sigstore), so there is no identity flag to pass
> ([#317](https://github.com/TomHennen/wrangle/issues/317)).

## Verifying the raw provenance

The VSA is the verdict; the underlying SLSA provenance is also independently
checkable. For Go, Python, and npm artifacts it lives in GitHub's
attestation store for the adopter's repo, and `gh` fetches it by the
artifact's digest — no separate download:

```bash
gh attestation verify <artifact> \
  --repo <owner>/<repo> \
  --signer-workflow TomHennen/wrangle/.github/workflows/build_and_publish_<type>.yml
```

`--signer-workflow` ties the check to wrangle: verification fails unless
wrangle's
reusable workflow signed the provenance. For container images, wrangle's own
`verify` job checks the provenance referrer in the registry before the VSA
is emitted; consumers use the VSA path above.

## The timing model: publish first, attest second

Go and container builds publish inline (goreleaser / `docker push`) and the
attest + verify jobs complete shortly after — typically 30s–2min. This is
fine because the SLSA contract is "consumer runs the verifier", not
"consumer trusts that an attestation exists":

- Download during the gap and verify → "no attestation found" → treat as
  untrusted, retry later.
- Download after a wrangle-side verify failure → verification fails → reject
  the artifact. Broken provenance reaching the store does no harm; the
  verify step is what's load-bearing.
- Download without verifying → you've opted out of SLSA's guarantees.

## Ecosystem-native checks (Python / npm)

These complement the VSA with a registry-side root of trust — they prove
*who published*, not how the artifact was built:

- **npm**: `npm audit signatures` after install checks npm's L2 in-CLI
  attestation (expected: "has a verified attestation"). Not run by
  `npm install` by default — consumers must opt in.
- **PyPI**: PEP 740 attestations are stored alongside every wheel published
  with `attestations: true`; the wheel's PyPI page shows verification
  status, and `sigstore-python` verifies on the command line. `pip install`
  does not verify them by default.

For both, the upload-time `workflow_ref` validation only holds when legacy
token publishing is disabled on the registry — see each build type's
"Before first use". And either way, run the VSA check above too: these
checks prove who published, but only the VSA carries the SLSA Build L3
verdict.

## For adopters: gate your publish on the VSA

If your publish job lives in your own workflow (Python / npm), run
[`actions/verify-vsa`](../actions/verify-vsa/README.md) between
`download-artifact` and the publish step. It re-checks the bytes on *that*
runner against the signed VSA — including that the VSA names the resource
you're about to publish — fail-closed, so what you upload is exactly what
passed wrangle's policy. The publish jobs in
[`gh_workflow_examples/build_python.yml`](../gh_workflow_examples/build_python.yml)
and [`build_npm.yml`](../gh_workflow_examples/build_npm.yml) show it wired.
