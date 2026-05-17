# Wrangle Build Python

Build a Python package (wheel + sdist), run tests, generate an SBOM, and produce SLSA L3 build provenance — composing PyPI Trusted Publishing (PEP 740 attestations) with `slsa-github-generator`. The publish step itself runs in the adopter's own workflow because PyPI Trusted Publishing's OIDC token must come from the caller, not a reusable workflow ([pypi/warehouse#11096](https://github.com/pypi/warehouse/issues/11096)).

> **Note:** This README documents *currently-shipped* behavior. For the full design — architecture, security model, full step sequence — see [`SPEC.md`](./SPEC.md).

## Recommended companion: source scan

This action hardens *how* your artifact is produced. It does NOT scan your source — vulnerable deps in your lockfile, dangerous workflow triggers, or missing branch protection still slip through and would be faithfully L3-attested by wrangle as legitimately built. Pair this with wrangle's source-scan workflow ([`actions/scan/README.md`](../../../actions/scan/README.md)) to close that gap on every PR and push. Without it, an attacker who lands a malicious dep or workflow misconfiguration routes around the build-side hardening — the May 2026 Mini Shai-Hulud compromise of TanStack/router is the canonical recent example.

## Build Track level

Consumed through wrangle's reusable workflow (`build_and_publish_python.yml`), the python build meets **SLSA v1.2 Build L3** — for both the pip and the uv sub-path. You do not need to reason about individual SLSA L3 requirements to use this — the single Build Track level is the claim. Two conditions narrow it:

- **Reusable consumption only.** Calling the `build/actions/python` composite directly from a workflow you author yourself forfeits the build-vs-sign job separation and is **not** a supported L3 path.
- **GitHub-hosted runners only.** Self-hosted runners invalidate the build-environment isolation the L3 verdict assumes.

On the uv sub-path, release builds run with the uv cache disabled (`setup-uv`'s `enable-cache: false`), so the attested artifact cannot be influenced by a shared, cross-build cache that uv does not re-verify on cache hits (SLSA's "Isolated" requirement). PR builds keep the cache for fast iteration — they produce no attested artifact. The pip sub-path consumes no cross-build cache in either case. The full per-builder analysis is [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) (Finding 1).

## Before first use

1. **Configure a Trusted Publisher on PyPI.** Project → Publishing → Add a trusted publisher. Specify your GitHub repository, workflow filename (`build_python.yml`), and optionally an environment name.

2. **Disable legacy API token uploads on PyPI** (Project → Publishing). PyPI allows both Trusted Publishing AND legacy API tokens by default. **A stolen or leftover token bypasses your CI entirely** — including all of wrangle's hardening — because the attacker can `twine upload` malicious artifacts directly without ever triggering your trusted workflow. This is exactly the attack vector behind the December 2024 ultralytics compromise and the May 2026 `mistralai` / `guardrails-ai` compromise (both shipped malware to PyPI by pushing directly to the registry, never triggering the legitimate GitHub Actions release workflow). Wrangle's pipeline can't enforce this; the toggle lives in PyPI's settings.

3. **(Optional) Configure TestPyPI.** For pre-release testing, repeat step 1 on test.pypi.org with a separate Trusted Publisher.

## Quick-start

Two ways to adopt:

1. **Reusable workflow** — single `uses:` line in your CI. Runs the full pipeline (build → test → SBOM → SLSA L3 provenance), with a publish job in your own workflow. This is what most adopters want.

   ```yaml
   jobs:
     build:
       permissions:
         # Required because wrangle's reusable workflow has a nested
         # provenance job that calls slsa-github-generator. GitHub
         # validates these permissions at workflow startup.
         contents: write   # SLSA generator's upload-assets job (write required even when upload-assets is false)
         id-token: write   # OIDC for Sigstore signing
         actions: read     # SLSA generator detects the GitHub Actions environment
       uses: TomHennen/wrangle/.github/workflows/build_and_publish_python.yml@v0.2.0
       with:
         path: "."
   ```

   Then add a publish job. See [`gh_workflow_examples/build_python.yml`](../../../gh_workflow_examples/build_python.yml) for the full template, including verifying SLSA provenance before publish.

2. **Composite action** — drop into an existing workflow. Runs build + test + SBOM only; you wire in your own provenance and publish.

   ```yaml
   - uses: TomHennen/wrangle/build/actions/python@v0.2.0
     with:
       path: "."
   ```

## What this action does

- Detects whether the project uses `uv` (presence of `uv.lock`) or standard PEP 517 tooling, and uses the right tool for dependencies, build, and tests.
- Installs the project (`pip install -e ".[test]"` or `uv sync`).
- Runs `pytest` if `tests/`, `test/`, or `[tool.pytest.ini_options]` is present in `pyproject.toml`. Discovery follows pytest's default convention — see [pytest's "Good Integration Practices"](https://docs.pytest.org/en/stable/explanation/goodpractices.html).
- Builds wheel + sdist via `python -m build` or `uv build`.
- Generates an SPDX SBOM via `syft`, installed and Cosign-keyless-verified by `tools/syft/install.sh`.
- Computes SHA-256 hashes of the built artifacts in the format `slsa-github-generator`'s `base64-subjects` input expects.

## Outputs from the reusable workflow

- `dist-artifact-name` — workflow-artifact name to download with `actions/download-artifact` to retrieve the built wheel + sdist.
- `provenance-artifact-name` — workflow-artifact name for the SLSA provenance (empty when `should-release` is false). Format: `python-<shortname>.intoto.jsonl` so multiple python builds in one workflow don't collide on the same artifact name. (When [#181](https://github.com/TomHennen/wrangle/issues/181) ships, consumers will see a single bundled `multiple.intoto.jsonl` on the release; the per-build namespaced files will become workflow-internal intermediates.)
- `metadata-artifact-name` — workflow-artifact name for the SBOM and any scan output (`python-metadata-<shortname>`). See [`docs/SPEC.md`](../../../docs/SPEC.md) "Unified metadata layout."
- `should-release` — `"true"` if the current event matches `release-events`. Your publish job MUST gate on this (see below).
- `hashes`, `version`.

## Controlling when releases happen

The `release-events` input controls which events produce SLSA provenance. Your publish job MUST also gate on `should-release` so wrangle's provenance gating and your publish gating stay in lockstep.

> **Required wiring.** Without the gate, your publish job runs on every non-PR event regardless of what you pass as `release-events`. The example workflow at [`gh_workflow_examples/build_python.yml`](../../../gh_workflow_examples/build_python.yml) shows the canonical shape:
>
> ```yaml
> publish:
>   if: ${{ needs.build.outputs.should-release == 'true' }}
>   needs: [build]
> ```
>
> Wrangle cannot enforce this from inside its reusable workflow — publish lives in your workflow due to PyPI Trusted Publishing's OIDC `workflow_ref` constraint ([pypi/warehouse#11096](https://github.com/pypi/warehouse/issues/11096)). If you forget the gate, builds still succeed, provenance still respects `release-events`, but your publish runs more often than you intended.

`release-events` accepts: `non-pull-request` (default), `tag-only`, `main-and-tags`, or a comma-separated `github.event_name` list (e.g., `push,workflow_dispatch`). See [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating" for the full vocabulary.

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_python.yml@v0.2.0
with:
  path: "."
  release-events: tag-only   # only tag pushes mint provenance and publish
```

## SLSA provenance verification (default-on, opt-out)

Wrangle's reusable workflow generates non-falsifiable SLSA L3 build provenance via `slsa-github-generator`, **then verifies the just-built dist against that provenance** before declaring the workflow successful. If verification fails, the workflow fails — and your publish job is blocked via standard `needs:` propagation. This catches the case where the dist is tampered with between wrangle's build and your publish.

You don't need to wire `slsa-verifier` into your own publish job. The example workflow's publish job is just `download-artifact` + `pypa/gh-action-pypi-publish`.

To opt out (e.g., you maintain a custom verification flow), pass `verify-provenance: false`:

```yaml
uses: TomHennen/wrangle/.github/workflows/build_and_publish_python.yml@v0.2.0
with:
  path: "."
  verify-provenance: false   # skip wrangle's verification; you handle it
```

When opted out, the dist's integrity between wrangle's build and your publish becomes your concern. The boilerplate to add a verify step in your own publish job is the same shape wrangle uses internally — see the [reusable workflow source](../../../.github/workflows/build_and_publish_python.yml) for reference.

## Verifying after install (downstream consumers)

Your package's consumers — anyone who installs your wheel — can verify it two complementary ways. Each answers a different question, and they trust different roots.

### PEP 740 attestations (against PyPI)

PyPI stores Sigstore-based PEP 740 attestations alongside every wheel published with `attestations: true` (which `pypa/gh-action-pypi-publish` does in the example workflow). These prove **who published the package** — the GitHub workflow identity, recorded in Sigstore's transparency log. `pip` verifies them natively (experimental as of pip 24.x); `sigstore-python` verifies them on the command line. The wheel's PyPI page also displays the verification status. No download from your repo needed — PyPI is the source of truth.

> **Known limitation.** `pip install` does NOT verify PEP 740 attestations by default — verification is experimental in pip 24.x and requires opt-in flags. Until verification is the default, consumers who care about provenance must opt in via `sigstore-python` or pip's experimental flag. This is a pip-ecosystem gap, not a wrangle gap; the legitimate-publish guarantee ("this version was published from the registered trusted workflow") is enforced by PyPI at *upload* time — but only when legacy token uploads are disabled (see "Before first use" above), since a stolen token bypasses that enforcement entirely.

### SLSA L3 provenance (against your repo's release)

SLSA provenance proves **how the artifact was built** — inputs, builder, materials — and is non-falsifiable because the generator runs in an isolated reusable workflow. Wrangle uploads the provenance to your GitHub release on tag pushes (because the reusable workflow sets `upload-assets: ${{ startsWith(github.ref, 'refs/tags/') }}`). The filename today is `python-<shortname>.intoto.jsonl` (e.g., `python-_.intoto.jsonl` for a top-level project, where `_` is the shortname for `.`). [#181](https://github.com/TomHennen/wrangle/issues/181) tracks moving to a single `multiple.intoto.jsonl` bundle (in-toto convention) at the release/consumer layer; until that ships, use the per-build filename. Verify with `slsa-verifier`:

```bash
# Download wheel + provenance from your GitHub release
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/<package>-<version>-py3-none-any.whl"
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/python-<shortname>.intoto.jsonl"

# Install slsa-verifier (https://github.com/slsa-framework/slsa-verifier#installation)

# Verify
slsa-verifier verify-artifact \
  --provenance-path python-<shortname>.intoto.jsonl \
  --source-uri "github.com/<owner>/<repo>" \
  <package>-<version>-py3-none-any.whl
```

Provenance is **only** in the GitHub release on tag pushes. On non-tag publishes (e.g., `workflow_dispatch` from a branch) the provenance lives only as a 90-day workflow artifact and is not retrievable by external consumers. Adopters whose workflows don't push tags should publicize how to obtain provenance — wrangle's convention is "tag pushes attach provenance to the release; non-tag publishes don't have consumer-retrievable provenance."

The same `slsa-verifier verify-artifact` invocation is exercised by wrangle's integration test against TestPyPI in [`gh_workflow_examples/build_python.yml`](../../../gh_workflow_examples/build_python.yml)'s publish job (which downloads provenance from a workflow artifact instead of a release asset, but the verify call is identical). Consumer-side verification against a real GitHub release is not yet integration-tested; see [#163](https://github.com/TomHennen/wrangle/issues/163).

## SBOM

The action writes an SPDX JSON SBOM to `metadata/python/<shortname>/sbom.spdx.json`. The reusable workflow zips the contents of `metadata/python/<shortname>/` and uploads them as the workflow artifact `python-metadata-<shortname>`, exposed as the `metadata-artifact-name` output. Downloading the artifact (e.g., via `actions/download-artifact`) extracts the metadata files at the top level of whatever `path:` the adopter chooses — the `metadata/python/<shortname>/` prefix is a workspace convention, not part of the artifact's interior layout.

Naming and layout follow the unified-metadata convention shared across every build type — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Unified metadata layout" for how the directory maps to the artifact zip.

```yaml
- uses: actions/download-artifact@<sha>
  with:
    name: ${{ needs.build.outputs.metadata-artifact-name }}
    path: metadata/  # `sbom.spdx.json` lands directly here, not under metadata/python/<shortname>/
```

`<shortname>` is the path-derived short name — `.` becomes `_`, `pkg/foo` becomes `pkg_foo`. This namespacing lets you run multiple python builds in one workflow without artifact-name collisions.

## Further reading

- [`SPEC.md`](./SPEC.md) — this action's full specification
- [`../../../docs/SPEC.md`](../../../docs/SPEC.md) — wrangle's overall architecture
- [`../../README.md`](../../README.md) — the build/ directory overview
- [`../../../actions/scan/README.md`](../../../actions/scan/README.md) — recommended source-scan companion
- [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/) — the underlying PyPI feature
- [SLSA generic generator](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md)
