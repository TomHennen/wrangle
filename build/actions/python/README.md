# Wrangle Build Python

Build a Python package (wheel + sdist), run pytest, generate an SBOM, and produce SLSA L3 provenance. Publish goes to PyPI via Trusted Publishing.

The publish job lives in your own workflow — not in a wrangle reusable workflow — because PyPI's OIDC token must come from the caller ([pypi/warehouse#11096](https://github.com/pypi/warehouse/issues/11096)).

## Quick-start

Copy [`gh_workflow_examples/build_python.yml`](../../../gh_workflow_examples/build_python.yml) into your repo at `.github/workflows/`. The example wires the required permissions (`attestations: write` so wrangle's attest job can write the GitHub-issued provenance, `id-token: write` for Sigstore keyless signing, `contents: write` so the verify job can attach the VSA to the release on tag pushes) and includes the publish job. Most adopters only need to set the `path` input.

The `build_and_publish_python.yml` workflow embeds [source scan](../../../actions/scan/README.md) via its `scan-tools` input — build hardens *how* your artifact is produced, source scan covers *what was checked into the repo you're building from*, and a load-bearing finding fails the run (blocking publish). The caller MUST grant `actions: read` and `security-events: write` for the scan (the example wires them; omitting either fails the run at startup). No separate `check_source_change.yml` needed.

For the composite-only path (build + test + SBOM; you wire your own provenance and publish), use `TomHennen/wrangle/build/actions/python@v0.2.0` as a step.

This README documents shipped behavior. For architecture and the full step sequence, see [`SPEC.md`](./SPEC.md).

## Before first use

1. **Configure a Trusted Publisher on PyPI.** Pin your GitHub repo, workflow filename (`build_python.yml`), and optionally an environment.
   - **Migrating an existing project:** Project → Publishing → Add a trusted publisher.
   - **Brand-new package (not yet on PyPI):** use PyPI's [pending publisher](https://docs.pypi.org/trusted-publishers/creating-a-project-through-oidc/) flow — Your projects → Publishing → Add a pending publisher. The first successful CI publish then creates the project. No manual bootstrap-publish needed (unlike npm).
2. **Disable legacy API token uploads on PyPI** (Publishing settings). **A stolen or leftover token bypasses your CI entirely**: an attacker can `twine upload` directly to the registry without ever triggering your trusted workflow — the attack vector behind the December 2024 ultralytics and May 2026 mistralai / guardrails-ai compromises. Wrangle can't enforce this; the toggle lives in PyPI's settings. For brand-new packages there's no legacy token to revoke; just leave the toggle off from the start.
3. **(Optional) Configure TestPyPI** with a separate Trusted Publisher for pre-release testing.

## Build Track level

Consumed through `build_and_publish_python.yml`, the build meets **SLSA v1.2 Build L3** — for both the pip and the uv sub-path — if both of these conditions hold:

- **Reusable consumption only.** Calling the composite directly forfeits the build-vs-sign job separation and is **not** a supported L3 path.
- **GitHub-hosted runners only.** Self-hosted runners invalidate the build-environment isolation L3 assumes.

On the uv sub-path, release builds disable `setup-uv`'s cache (uv doesn't re-verify cache hits — would violate SLSA's "Isolated" requirement); PR builds keep it for fast iteration. The pip sub-path uses no cross-build cache. Full analysis: [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) Finding 1.

## What this action does

- Detects whether the project uses `uv` (presence of `uv.lock`) or standard PEP 517 tooling, and uses the right tool for dependencies, build, and tests.
- Installs the project (`pip install -e ".[test]"` or `uv sync`).
- Runs `pytest` if `tests/`, `test/`, or `[tool.pytest.ini_options]` is present in `pyproject.toml`. Discovery follows pytest's default convention — see [pytest's "Good Integration Practices"](https://docs.pytest.org/en/stable/explanation/goodpractices.html).
- Builds wheel + sdist via `python -m build` or `uv build`.
- Generates an SPDX SBOM via `syft`, installed and Cosign-keyless-verified by `tools/syft/install.sh`.
- Computes SHA-256 hashes of the built artifacts, which the reusable workflow's `attest` job feeds to `actions/attest-build-provenance` as the provenance subjects.

## Outputs from the reusable workflow

- `dist-artifact-name` — workflow-artifact name to download with `actions/download-artifact` to retrieve the built wheel + sdist.
- `provenance-artifact-name` — workflow-artifact name for the SLSA provenance bundle (empty when `should-release` is false). Format: `python-provenance-bundle-<shortname>` (a Sigstore bundle covering all dist subjects) so multiple python builds in one workflow don't collide on the same artifact name.
- `metadata-artifact-name` — workflow-artifact name for the SBOM and any scan output (`python-metadata-<shortname>`). See [`docs/SPEC.md`](../../../docs/SPEC.md) "Unified metadata layout."
- `should-release` — `"true"` if the package should be released. Today that means the event matched `release-events`; future versions may apply additional checks, so treat the output as the source of truth rather than re-evaluating `release-events` yourself. Your publish job MUST gate on this (see below).
- `resource-uri` — the purl the VSA's `resourceUri` names (`pkg:generic/<name>@<version>`). Pipe into [`actions/verify-vsa`](../../../actions/verify-vsa/README.md)'s `resource-uri` input.
- `hashes`, `version`.

`<shortname>` is path-derived (`.` → `_`, `pkg/foo` → `pkg_foo`) so multiple python builds in one workflow don't collide on artifact names.

## Controlling when releases happen

`release-events` controls which events trigger release-time actions: SLSA provenance generation, verification, and — via the `should-release` output — your downstream publish job. Accepted values:

- `non-pull-request` (default) — every event except `pull_request`.
- `tag-only` — only `push` events to `refs/tags/*`.
- `main-and-tags` — `push` to `refs/heads/main` or `refs/tags/*`.
- A comma-separated `github.event_name` list (e.g., `push,workflow_dispatch`).

See [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating" for the full vocabulary.

```yaml
with:
  path: "."
  release-events: tag-only
```

> **Required wiring.** Your publish job MUST also gate on `should-release` — wrangle can't enforce this because publish lives in your workflow (PyPI's OIDC constraint). The canonical shape:
>
> ```yaml
> publish:
>   if: ${{ needs.build.outputs.should-release == 'true' }}
>   needs: [build]
> ```
>
> Without the gate, publish runs on every non-PR event regardless of `release-events`.

## SLSA provenance verification (the `verify` job)

The `verify` job verifies the SLSA L3 provenance — ampel (via `actions/verify`) checks the provenance's Sigstore signature against the wrangle PolicySet's `common.identities` (fail-closed: only wrangle's reusable-workflow signer passes) and the SLSA tenets, then emits the signed VSA. It's gated on `should-release`, so it runs on every release; it is not opt-out-able. If verification fails the workflow fails and your publish job is blocked via `needs:`. That gate alone doesn't bind the publish job's *bytes* — it downloads its own copy of the dist — so the example's publish job also runs [`actions/verify-vsa`](../../../actions/verify-vsa/README.md) against its download before `pypa/gh-action-pypi-publish` uploads it.

## Verifying after install (downstream consumers)

Two complementary verification paths, different roots of trust:

**PEP 740 attestations (against PyPI).** PyPI stores Sigstore-based attestations alongside every wheel published with `attestations: true` (which `pypa/gh-action-pypi-publish` does). Proves *who published* — the GitHub workflow identity, recorded in Sigstore's transparency log. The wheel's PyPI page shows verification status; `sigstore-python` verifies on the command line.

> **Known limitation.** `pip install` does NOT verify PEP 740 attestations by default (experimental in pip 24.x). Until verification is the default, the load-bearing check is PyPI's upload-time `workflow_ref` validation — but that only holds when legacy token uploads are disabled (see "Before first use"), since a stolen token bypasses it entirely.

**SLSA L3 provenance (against GitHub's attestation store).** Proves *how the artifact was built* — inputs, builder, materials. Non-falsifiable because the attest step runs inside wrangle's isolated reusable workflow, which is named as the provenance's `builder.id` and as the Sigstore signing identity. The provenance is stored in GitHub's attestation store for your repo (not attached to the release), so a consumer verifies the downloaded wheel against it with `gh attestation verify`:

```bash
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/<package>-<version>-py3-none-any.whl"

gh attestation verify "<package>-<version>-py3-none-any.whl" \
  --repo <owner>/<repo> \
  --signer-workflow TomHennen/wrangle/.github/workflows/build_and_publish_python.yml
```

`--signer-workflow` is the binding: it fails closed unless wrangle's reusable workflow signed the provenance. `gh` fetches the attestation from GitHub's store by the wheel's digest, so no separate provenance file download is needed.

### Verifying the VSA

On tag pushes wrangle also attaches a signed SLSA Verification Summary Attestation (VSA) per dist file — `<dist-file>.intoto.jsonl` (the wheel or sdist) — to the GitHub release, recording that the build provenance passed the `wrangle-provenance-python-v1` PolicySet. A consumer trusts that one signed VSA instead of re-running the policy engine. It is keyless-signed by **wrangle's** reusable workflow (`build_and_publish_python.yml`), not your own. Its `resourceUri` is `pkg:generic/<name>@<version>` — pin that exact string.

Grab the VSA from the release:

```bash
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/<dist-file>.intoto.jsonl"
```

**Recommended — `ampel verify` (one command).** The complete check in a single command: ampel confirms the signature, the keyless signer identity (wrangle's reusable workflow), **your origin repository** — the policy's `sourceRepositoryUriMatch` binds the signing cert's source-repository extension to the `sourceRepo` you pass, proving *which repo* built the artifact — and the predicate fields (`verificationResult` / `resourceUri` / `verifiedLevels`), against a wrangle-hosted consumer policy fetched by locator (you author no policy). Requires [ampel](https://github.com/carabiner-dev/ampel) ≥ v1.3.0 (one Go binary); both context values are required, so omitting one is a hard error, never a weaker check:

```bash
ampel verify \
  --subject <dist-file> \
  --policy git+https://github.com/TomHennen/wrangle@<version>#policies/wrangle-vsa-consumer-v1.hjson \
  --attestation <dist-file>.intoto.jsonl \
  --context expectedResourceUri:pkg:generic/<name>@<version> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

**Without ampel — `cosign verify-blob-attestation` + `jq`.** The same complete check from cosign: it confirms the signature, the signer identity, your origin repository (`--certificate-github-workflow-repository`), and that the dist file's hash matches the VSA subject. cosign doesn't read predicate fields, so a `jq` decode covers them:

```bash
cosign verify-blob-attestation --bundle <dist-file>.intoto.jsonl --new-bundle-format \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/TomHennen/wrangle/\.github/workflows/build_and_publish_python\.yml@refs/tags/v' \
  --certificate-github-workflow-repository <your-org>/<your-repo> \
  --type https://slsa.dev/verification_summary/v1 \
  <dist-file>

payload="$(jq -r '.dsseEnvelope.payload' <dist-file>.intoto.jsonl | base64 -d)"
jq -e '.predicate.verificationResult == "PASSED"' <<<"$payload"
jq -e '.predicate.resourceUri == "pkg:generic/<name>@<version>"' <<<"$payload"
jq -e '.predicate.verifiedLevels | index("SLSA_BUILD_LEVEL_3")' <<<"$payload"
```

`--type` must be the full URI `https://slsa.dev/verification_summary/v1` — cosign rejects the `slsaverificationsummary` alias.

## SBOM

Written to `metadata/python/<shortname>/sbom.spdx.json` and uploaded as the `python-metadata-<shortname>` workflow artifact (exposed via the `metadata-artifact-name` output). Download lands the files at the top level of whatever `path:` you pick — the `metadata/python/<shortname>/` prefix is a workspace convention, not preserved in the zip. See [`docs/SPEC.md`](../../../docs/SPEC.md) "Unified metadata layout".

## Further reading

- [`SPEC.md`](./SPEC.md) — this action's full specification.
- [`../../../docs/SPEC.md`](../../../docs/SPEC.md) — wrangle's architecture.
- [`../../../actions/scan/README.md`](../../../actions/scan/README.md) — the embedded source scan (`scan-tools` input).
- [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/), [actions/attest-build-provenance](https://github.com/actions/attest-build-provenance).
