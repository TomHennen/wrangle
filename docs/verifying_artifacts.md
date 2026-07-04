# Verifying wrangle-built artifacts

Wrangle produces two attestations for every released artifact:

- **SLSA Build L3 provenance** — *how the artifact was built*: the builder, the
  source commit, the workflow. Produced by `actions/attest-build-provenance`
  inside wrangle's isolated reusable workflow and stored in GitHub's
  attestation store for the adopter's repo.
- **A SLSA Verification Summary Attestation (VSA)** — *the policy verdict*:
  a signed record that the artifact passed wrangle's policy at SLSA
  Build L3. Keyless-signed by **wrangle's** reusable workflow (not the
  adopter's). For Go, Python, and npm builds the VSA rides in a per-artifact
  `<artifact>.intoto.jsonl` bundle attached to the GitHub release (a JSONL
  in-toto bundle carrying the provenance plus that artifact's VSA). Container
  builds produce no GitHub release: the VSA is pushed to the registry as its
  own OCI referrer on the image digest (one VSA statement, which round-trips
  cleanly by digest), so `ampel`/`cosign` can fetch it without a download —
  provenance is a separate referrer. The combined `<artifact>.intoto.jsonl`
  bundle (provenance + VSA) is also uploaded as a workflow artifact. For every
  build type the VSA is *also* posted to your repo's GitHub attestation store,
  so a consumer can fetch it by digest with no download — see [by-digest
  fetch](#by-digest-from-the-github-attestation-store) below.

A consumer's one-command check is the VSA: it carries the full verdict, so
you trust one signature instead of re-running the policy engine.

## What to plug in, per ecosystem

| Build type | VSA location | `resourceUri` to expect | Signing workflow |
|---|---|---|---|
| Go | GitHub release, `<artifact>.intoto.jsonl` | `pkg:golang/<module-path>@<version>` (the `module` directive in `go.mod`) | `build_and_publish_go.yml` |
| Python | GitHub release, `<artifact>.intoto.jsonl` | `pkg:pypi/<name>@<version>` (name [PEP 503-normalized](https://peps.python.org/pep-0503/#normalized-names)) | `build_and_publish_python.yml` |
| npm | GitHub release, `<artifact>.intoto.jsonl` | `pkg:npm/<name>@<version>` (scoped names verbatim, e.g. `pkg:npm/@scope/pkg@1.2.3`) | `build_and_publish_npm.yml` |
| Container | VSA as its own OCI referrer on the image digest; combined `<artifact>.intoto.jsonl` (workflow artifact) | `<imagename>@sha256:<digest>` | `build_and_publish_container.yml` |

## What's on the GitHub release

For Go, Python, and npm, a tag push attaches a verify-pair per artifact —
the dist `<artifact>` and its `<artifact>.intoto.jsonl` bundle — so a consumer
downloads both by name and verifies. The build's SBOM and scan results ride in
a single `<type>-metadata-<sn>.zip` (the same [unified metadata
layout](metadata_layout.md)), not as separate assets. (Go's dist archives
and `checksums.txt` are attached by goreleaser; wrangle adds the bundle + zip.)
Container builds publish no release — the VSA is an OCI referrer on the image
digest (see below). Adopters can suppress the attach with the verify action's
`attach-release-assets: false`.

wrangle creates the Release for the tag automatically if none exists; pre-create
one yourself only for custom notes or a draft — see the per-language build READMEs.

### A real example (the showcase Go release)

The [`wrangle-test`](https://github.com/TomHennen/wrangle-test) showcase
publishes a Go release you can verify yourself. Tag `v20260621-fa5bd7f`
includes, for its Go build:

- `wrangle-test-fixture-go_20260621-fa5bd7f_linux_amd64.tar.gz` — the archive
- `wrangle-test-fixture-go_20260621-fa5bd7f_linux_amd64.tar.gz.intoto.jsonl` — its bundle (provenance + VSA)
- `go-metadata-go.zip` — the [unified metadata](metadata_layout.md) (SBOM + scan results)
- `checksums.txt` — goreleaser's archive checksums

Download the archive and its bundle:

```bash
base=https://github.com/TomHennen/wrangle-test/releases/download/v20260621-fa5bd7f
curl -sSLO "$base/wrangle-test-fixture-go_20260621-fa5bd7f_linux_amd64.tar.gz"
curl -sSLO "$base/wrangle-test-fixture-go_20260621-fa5bd7f_linux_amd64.tar.gz.intoto.jsonl"
```

The showcase builds from `main`, not a release tag, so its VSA carries a
`@refs/heads/main` signer identity — the strict `v*` consumer policy rejects it
by design. Use the `nonstrict` policy, which accepts any ref:

```bash
ampel verify --subject wrangle-test-fixture-go_20260621-fa5bd7f_linux_amd64.tar.gz \
  --policy git+https://github.com/TomHennen/wrangle@v0.3.1#policies/wrangle-vsa-consumer-nonstrict-v1.hjson \
  --collector jsonl:wrangle-test-fixture-go_20260621-fa5bd7f_linux_amd64.tar.gz.intoto.jsonl \
  --context expectedResourceUri:pkg:golang/github.com/tomhennen/wrangle-test/go@v20260621-fa5bd7f \
  --context sourceRepo:https://github.com/TomHennen/wrangle-test
```

For your own releases — built by pinning wrangle's reusable workflows to a
release tag — swap `wrangle-vsa-consumer-nonstrict-v1` for the strict
`wrangle-vsa-consumer-v1`.

## Recommended: `ampel verify` (one command)

[ampel](https://github.com/carabiner-dev/ampel) ≥ v1.3.0 (one Go binary)
checks everything that matters in a single command: these exact bytes are
what passed policy, wrangle signed the verdict, **your repo built the
artifact** (not a fork, not someone else's wrangle build), and the verdict
is PASSED at SLSA Build L3. The policy is wrangle-hosted and fetched by
locator, so you author nothing. Both `--context` values are required;
omitting one is a hard error, never a weaker check.

For file artifacts (Go / Python / npm), download the artifact and its
`<artifact>.intoto.jsonl` bundle from the release, then — ampel reads the JSONL
bundle and self-selects the VSA matching `--subject`:

```bash
ampel verify --subject <artifact> \
  --policy git+https://github.com/TomHennen/wrangle@v0.3.1#policies/wrangle-vsa-consumer-v1.hjson \
  --collector jsonl:<artifact>.intoto.jsonl \
  --context expectedResourceUri:<resourceUri from the table above> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

For container images, ampel fetches the VSA from the registry referrer — no
download step:

```bash
ampel verify --subject sha256:<digest> \
  --policy git+https://github.com/TomHennen/wrangle@v0.3.1#policies/wrangle-vsa-consumer-v1.hjson \
  --collector oci:<imagename>@sha256:<digest> \
  --context expectedResourceUri:<imagename>@sha256:<digest> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

The VSA rides as its own by-digest referrer, so the `oci:` collector finds it
from just the image reference. The combined `<sha256-digest>.intoto.jsonl`
bundle (provenance + VSA) is also available from the workflow-run artifacts if
you'd rather verify from the file: `--collector jsonl:<sha256-digest>.intoto.jsonl`.

### By-digest, from the GitHub attestation store

The VSA also lands in your repo's GitHub attestation store, so ampel's
`github:` collector fetches it by subject digest with no download — for every
build type, including a container image by its OCI digest:

```bash
ampel verify --subject sha256:<digest> \
  --policy git+https://github.com/TomHennen/wrangle@v0.3.1#policies/wrangle-vsa-consumer-v1.hjson \
  --collector github:<your-org>/<your-repo> \
  --context expectedResourceUri:<resourceUri from the table above> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

Pin the policy locator to any wrangle `v*` release tag — it does **not**
need to match the wrangle version the adopter builds with. The `-v1` in the
policy filename is the contract version; any release tag carrying that file
verifies any wrangle-signed VSA.

## What `verifiedLevels` carries

Beyond `SLSA_BUILD_LEVEL_3`, the VSA lists a `WRANGLE_*` marker per wrangle
check that passed — the full set and their meaning are in
[SPEC.md §Release verification](SPEC.md#release-verification). The
`ampel verify` commands above echo them in the PASS details
(`verifiedLevels: SLSA_BUILD_LEVEL_3, WRANGLE_HAS_SBOM, …`). To read them
straight from a release bundle, or gate on one (append
`| grep -qx WRANGLE_HAS_SBOM`):

```bash
jq -r 'select(.dsseEnvelope).dsseEnvelope.payload | @base64d | fromjson
  | select(.predicateType == "https://slsa.dev/verification_summary/v1")
  | .predicate.verifiedLevels[]' <artifact>.intoto.jsonl
```

## Without ampel: cosign + jq

cosign performs the same complete check, minus predicate-field reads — so a
`jq` decode covers `verificationResult` / `resourceUri` / `verifiedLevels`.

For file artifacts (`cosign verify-blob-attestation`). `--bundle` takes a
single DSSE bundle, so first pull the VSA line out of the artifact's JSONL
bundle by its subject digest (`cosign verify-blob-attestation` then binds those
bytes to `<artifact>`):

```bash
digest="$(sha256sum <artifact> | cut -d' ' -f1)"
jq -c "select(.dsseEnvelope.payload | @base64d | fromjson
  | .predicateType == \"https://slsa.dev/verification_summary/v1\"
  and any(.subject[]; .digest.sha256 == \"$digest\"))" \
  <artifact>.intoto.jsonl > vsa.intoto.jsonl

cosign verify-blob-attestation --bundle vsa.intoto.jsonl --new-bundle-format \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_<type>\.yml@refs/tags/v[0-9.]+$' \
  --certificate-github-workflow-repository <your-org>/<your-repo> \
  --type https://slsa.dev/verification_summary/v1 \
  <artifact>

payload="$(jq -r '.dsseEnvelope.payload' vsa.intoto.jsonl | base64 -d)"
jq -e '.predicate.verificationResult == "PASSED"' <<<"$payload"
jq -e '.predicate.resourceUri == "<resourceUri from the table above>"' <<<"$payload"
jq -e '.predicate.verifiedLevels | index("SLSA_BUILD_LEVEL_3")' <<<"$payload"
```

Substitute `<type>` with `go`, `python`, or `npm`. The `@refs/tags/v…` anchor
is the identity wrangle's policy requires: pin wrangle's reusable workflows by
release tag (`@vX.Y.Z`) so the VSA's signing cert records `@refs/tags/vX.Y.Z`.
A SHA-pinned wrangle still builds, but its VSA carries a bare `@<sha>` identity
and won't verify here — or under the consumer policy below, or your own
`verify-vsa` publish gate. Requiring a release tag does not stop you pinning an
old (possibly vulnerable) release; it raises the floor from any commit to any
release. `--type` must be the full URI — cosign rejects the
`slsaverificationsummary` alias.

For container images the VSA is an OCI referrer on the image digest, not a
`sha256-<digest>.att` tag, so `cosign verify-attestation` cannot find it. Pull
the VSA referrer bundle with `cosign download attestation` (which lists each
referrer bundle on its own line), select the VSA line, then bind it to the image
digest with `cosign verify-blob-attestation --new-bundle-format` — a digest
subject has no file blob, so pass `--digest`/`--digestAlg` in place of a path:

```bash
imagename=<imagename>; digest=<digest>   # the sha256 hex, no "sha256:" prefix

cosign download attestation "$imagename@sha256:$digest" \
  | jq -c "select(.dsseEnvelope.payload | @base64d | fromjson
    | .predicateType == \"https://slsa.dev/verification_summary/v1\")" > vsa.intoto.jsonl

cosign verify-blob-attestation --bundle vsa.intoto.jsonl --new-bundle-format \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_container\.yml@refs/tags/v[0-9.]+$' \
  --certificate-github-workflow-repository <your-org>/<your-repo> \
  --type https://slsa.dev/verification_summary/v1 \
  --digest "$digest" --digestAlg sha256

payload="$(jq -r '.dsseEnvelope.payload' vsa.intoto.jsonl | base64 -d)"
jq -e '.predicate.verificationResult == "PASSED"' <<<"$payload"
jq -e ".predicate.resourceUri == \"$imagename@sha256:$digest\"" <<<"$payload"
jq -e '.predicate.verifiedLevels | index("SLSA_BUILD_LEVEL_3")' <<<"$payload"
```

If you'd rather verify from the file, the combined `<sha256-digest>.intoto.jsonl`
workflow artifact carries the same VSA — swap the `cosign download attestation`
step for a `jq` filter over that file, exactly as the file-artifact path above
does. The `@refs/tags/v…` anchor is the strict release identity (see the
file-artifact note above); the showcase staging image is built SHA-pinned, so
its VSA carries a bare `@<sha>` identity and verifies only under a loosened
anchor.

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

The container build type publishes inline (`docker push`) and its attest +
verify jobs complete shortly after — typically 30s–2min. This is fine because
the SLSA contract is "consumer runs the verifier", not "consumer trusts that
an attestation exists":

- Download during the gap and verify → "no attestation found" → treat as
  untrusted, retry later.
- Download after a wrangle-side verify failure → verification fails → reject
  the artifact. Broken provenance reaching the store does no harm; the
  verify step is what's load-bearing.
- Download without verifying → you've opted out of SLSA's guarantees.

The go build type has no such gap: goreleaser only builds, and the verify
job is what uploads the attested archives + `checksums.txt` to the release —
so nothing is published before it is attested.

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
