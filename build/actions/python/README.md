# Wrangle Build Python

Build a Python package (wheel + sdist), run tests, generate an SBOM, and produce SLSA L3 build provenance — composing PyPI Trusted Publishing (PEP 740 attestations) with `slsa-github-generator`. The publish step itself runs in the adopter's own workflow because PyPI Trusted Publishing's OIDC token must come from the caller, not a reusable workflow ([pypi/warehouse#11096](https://github.com/pypi/warehouse/issues/11096)).

> **Note:** This README documents *currently-shipped* behavior. For the full design — architecture, security model, full step sequence — see [`SPEC.md`](./SPEC.md).

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
- `provenance-artifact-name` — workflow-artifact name for the SLSA provenance (empty on PR builds).
- `metadata-artifact-name` — workflow-artifact name for the SBOM and any scan output (`python-metadata-<shortname>`). See [`docs/SPEC.md`](../../../docs/SPEC.md) "Unified metadata layout."
- `hashes`, `version`.

## Verifying SLSA provenance before publish (recommended, optional)

Wrangle's reusable workflow generates non-falsifiable SLSA L3 build provenance via `slsa-github-generator`. The example workflow ([`gh_workflow_examples/build_python.yml`](../../../gh_workflow_examples/build_python.yml)) downloads that provenance, installs `slsa-verifier`, and runs `verify-artifact` against the dist before publishing:

```yaml
- uses: actions/download-artifact@<sha>
  with:
    name: ${{ needs.build.outputs.provenance-artifact-name }}
    path: provenance/
- uses: slsa-framework/slsa-verifier/actions/installer@<sha>
- name: Verify SLSA provenance
  env:
    SOURCE_URI: github.com/${{ github.repository }}
  run: |
    set -euo pipefail
    PROVENANCE="$(find provenance -maxdepth 1 -type f | head -n1)"
    slsa-verifier verify-artifact \
      --provenance-path "$PROVENANCE" \
      --source-uri "$SOURCE_URI" \
      dist/*
```

This step is **recommended but not required**. It catches the case where the provenance was generated for different artifacts than the ones you're about to publish — i.e., the dist was tampered with after build but before publish. If you don't need this guarantee, drop the download + installer + verify steps and publish directly.

## Verifying after install (downstream consumers)

Your package's consumers — anyone who installs your wheel — can verify it two complementary ways. Each answers a different question, and they trust different roots.

### PEP 740 attestations (against PyPI)

PyPI stores Sigstore-based PEP 740 attestations alongside every wheel published with `attestations: true` (which `pypa/gh-action-pypi-publish` does in the example workflow). These prove **who published the package** — the GitHub workflow identity, recorded in Sigstore's transparency log. `pip` verifies them natively (experimental as of pip 24.x); `sigstore-python` verifies them on the command line. The wheel's PyPI page also displays the verification status. No download from your repo needed — PyPI is the source of truth.

### SLSA L3 provenance (against your repo's release)

SLSA provenance proves **how the artifact was built** — inputs, builder, materials — and is non-falsifiable because the generator runs in an isolated reusable workflow. Wrangle uploads the provenance to your GitHub release on tag pushes (because the reusable workflow sets `upload-assets: ${{ startsWith(github.ref, 'refs/tags/') }}`). The default filename is `multiple.intoto.jsonl` (the SLSA generic generator's default for multi-artifact builds). Verify with `slsa-verifier`:

```bash
# Download wheel + provenance from your GitHub release
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/<package>-<version>-py3-none-any.whl"
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/multiple.intoto.jsonl"

# Install slsa-verifier (https://github.com/slsa-framework/slsa-verifier#installation)

# Verify
slsa-verifier verify-artifact \
  --provenance-path multiple.intoto.jsonl \
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

## Adopter onboarding (PyPI Trusted Publishing)

Before the first publish:

1. **Configure a Trusted Publisher on PyPI.** Project settings → Publishing → Add a trusted publisher. Specify your GitHub repository, workflow filename (`build_python.yml`), and optionally an environment name.
2. **Disable legacy API token uploads.** PyPI allows both Trusted Publishing and tokens by default. Disable tokens after configuring Trusted Publishing — this prevents the attack vector exploited in the December 2024 ultralytics compromise (stolen API token despite Trusted Publishing being configured). Wrangle cannot enforce this; PyPI is the authority.
3. **(Optional) Configure TestPyPI.** For pre-release testing, repeat step 1 on test.pypi.org with a separate Trusted Publisher.

## Further reading

- [`SPEC.md`](./SPEC.md) — this action's full specification
- [`../../../docs/SPEC.md`](../../../docs/SPEC.md) — wrangle's overall architecture
- [`../../README.md`](../../README.md) — the build/ directory overview
- [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/) — the underlying PyPI feature
- [SLSA generic generator](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md)
