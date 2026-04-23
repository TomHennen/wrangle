# Python Build Type — Specification

## Overview

The Python build type builds, tests, and publishes Python packages to PyPI with Sigstore attestations. It follows PyPI's Trusted Publishing model (OIDC, no API tokens) and PEP 740 attestations for supply chain provenance.

Unlike the container build type, Python packages don't need a separate SLSA generator or Cosign signing step — PyPI's native Sigstore integration (via `pypa/gh-action-pypi-publish`) handles attestation and signing in a single publish step.

## Design principles

### Use the ecosystem's own tools

Python has a mature, standardized build pipeline: `pyproject.toml` (PEP 621) declares metadata and build backend, `python -m build` (PEP 517) produces wheels and sdists, and `pypa/gh-action-pypi-publish` handles publishing with Trusted Publishing. Wrangle should compose these, not replace them.

### Support uv as a first-class alternative

[uv](https://github.com/astral-sh/uv) (from Astral) is a fast, Rust-based replacement for pip, virtualenv, and pip-tools. When a project uses uv (`uv.lock` present), the build action should use `uv` for dependency installation, building, and test execution. When uv is not present, fall back to standard PEP 517 tooling.

### No tokens required

PyPI Trusted Publishing uses GitHub's OIDC token to authenticate — no API tokens or secrets needed. The adopter configures a "trusted publisher" on PyPI (specifying their GitHub repo + workflow), and the publish action exchanges the OIDC token for a short-lived credential automatically. This is a major ergonomic advantage over other build types.

### Attestations are built-in

PEP 740 attestations are generated and uploaded by `pypa/gh-action-pypi-publish` when `attestations: true` is set. The attestations are Sigstore-based (Fulcio certificates, Rekor transparency log) and verified natively by PyPI. No separate signing or provenance step is needed.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `path` | No | `.` | Relative path to the directory containing `pyproject.toml` |
| `python-version` | No | `3.12` | Python version to use for building |
| `publish` | No | `true` | Whether to publish to PyPI. Set to `false` for PR builds or dry runs |
| `repository-url` | No | `https://upload.pypi.org/legacy/` | PyPI upload URL. Override for TestPyPI (`https://test.pypi.org/legacy/`) or private registries |
| `run-tests` | No | `true` | Whether to run pytest before publishing |

## Outputs

| Output | Description |
|--------|-------------|
| `version` | The package version that was built |
| `sdist` | Path to the built sdist (`.tar.gz`) |
| `wheel` | Path to the built wheel (`.whl`) |
| `sbom` | Path to the generated SBOM |

## Step sequence

### 1. Validate and normalize inputs

Same pattern as the container build type: reject absolute paths, path traversal, and invalid characters in `path`. Verify `pyproject.toml` (or `setup.py` as legacy fallback) exists at the specified path.

### 2. Detect tooling

Check for `uv.lock` in the project directory:
- **If present:** use `uv` for all operations (`uv sync`, `uv build`, `uv run pytest`)
- **If absent:** use standard PEP 517 tooling (`python -m venv`, `pip install`, `python -m build`, `pytest`)

Install `uv` via `astral-sh/setup-uv` if the uv path is chosen. Install Python via `actions/setup-python`.

### 3. Install dependencies

- **uv path:** `uv sync` (installs from `uv.lock`, creates venv automatically)
- **Standard path:** `python -m venv .venv && . .venv/bin/activate && pip install -e ".[test]"` (or `.[dev]`)

### 4. Run tests (if enabled)

Run `pytest` (or `uv run pytest` for uv projects). If no `tests/` directory and no `[tool.pytest]` section in `pyproject.toml`, skip gracefully with a message — same as the shell build skips when no `.bats` files are found.

### 5. Build

- **uv path:** `uv build` (produces wheel + sdist in `dist/`)
- **Standard path:** `python -m build` (same output)

Both delegate to whatever build backend `pyproject.toml` declares (setuptools, hatchling, flit, maturin, etc.).

### 6. Generate SBOM

Generate a CycloneDX SBOM from the project's dependencies using `cyclonedx-python` (or `syft` as fallback). Write to `metadata/python/<shortname>/sbom.cdx.json`.

### 7. Generate SLSA provenance

Use `actions/attest-build-provenance` to generate SLSA v1.0 provenance for the built wheel and sdist. This records the build inputs, builder identity, and materials in GitHub's attestation store. Verifiable via `gh attestation verify`.

### 8. Publish (if enabled)

Use `pypa/gh-action-pypi-publish` with:
- `attestations: true` — generates PEP 740 Sigstore attestations
- `packages-dir: dist/` — the built artifacts
- `repository-url: <from input>` — PyPI or TestPyPI

Trusted Publishing handles authentication via OIDC. No secrets needed. SLSA provenance is generated before publish (step 7) so the attestation covers the exact artifacts being uploaded.

### 9. Generate summary and upload metadata

Write a step summary (package name, version, PyPI URL, attestation status). Upload SBOM, SLSA provenance reference, and build metadata as a workflow artifact. See #150 for the vision of unified build results.

## Permissions

The reusable workflow requires:

```yaml
permissions:
  contents: read      # checkout
  id-token: write     # OIDC for PyPI Trusted Publishing, Sigstore attestations, and SLSA provenance
  attestations: write # GitHub attestation store for SLSA provenance
```

No `packages: write` (that's for GHCR). No secrets.

## Reusable workflow

`.github/workflows/build_and_publish_python.yml`:

```yaml
on:
  workflow_call:
    inputs:
      path:
        required: false
        type: string
        default: "."
      python-version:
        required: false
        type: string
        default: "3.12"
      publish:
        required: false
        type: boolean
        default: true
      repository-url:
        required: false
        type: string
        default: "https://upload.pypi.org/legacy/"
      run-tests:
        required: false
        type: boolean
        default: true

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
      attestations: write
    steps:
      - uses: actions/checkout@<sha>
      - uses: ./build/actions/python
        with:
          path: ${{ inputs.path }}
          python-version: ${{ inputs.python-version }}
          publish: ${{ inputs.publish }}
          repository-url: ${{ inputs.repository-url }}
          run-tests: ${{ inputs.run-tests }}
```

## Two layers of attestation

Python builds produce two complementary attestations:

1. **PEP 740 attestations** (via `pypa/gh-action-pypi-publish` with `attestations: true`) — Sigstore-based publisher identity attestations stored on PyPI. These prove **who published** the package (which repo, which workflow). PyPI verifies these natively.

2. **SLSA provenance** (via `actions/attest-build-provenance`) — SLSA v1.0 build provenance stored in GitHub's attestation store. This proves **how the artifact was built** (inputs, builder, materials). Verifiable via `gh attestation verify`.

PEP 740 attestations are the Python ecosystem's standard; SLSA provenance is the cross-ecosystem standard. Wrangle generates both because they answer different questions and are verified by different consumers.

## Security model

### Trusted Publishing

PyPI Trusted Publishing binds a specific GitHub repository + workflow + optional environment to a PyPI project. Only that exact workflow can publish. This is:
- **Stronger than API tokens** — tokens can be stolen; OIDC claims are tied to the workflow execution context
- **No secret management** — nothing to rotate, nothing to leak
- **Auditable** — every publish is traceable to a specific workflow run

### PEP 740 attestations

Sigstore-based attestations prove:
- The package was built by a specific GitHub Actions workflow
- The workflow ran in a specific repository at a specific commit
- The attestation is recorded in Sigstore's transparency log (Rekor)

PyPI verifies these attestations and displays verification status on package pages. Consumers can verify with `pip` (experimental) or `sigstore-python`.

### What wrangle adds

The adopter could wire up `python -m build` + `pypa/gh-action-pypi-publish` themselves. Wrangle adds:
- **SBOM generation** — automatic CycloneDX SBOM from dependencies
- **Test gating** — tests must pass before publish
- **Input validation** — path traversal prevention, safe defaults
- **Consistent metadata** — step summaries, artifact uploads, same structure as other build types
- **One-line adoption** — a single `uses:` line instead of a multi-step workflow

## Dependency scanning

OSV-Scanner supports all major Python lockfile formats:
- `pyproject.toml` (PEP 621 dependencies)
- `requirements.txt`
- `poetry.lock`
- `uv.lock`
- `Pipfile.lock`

The source scanning workflow (`check_source_change.yml`) handles this — no additional scanning needed in the build action. The SBOM scan is complementary, covering transitive dependencies resolved at build time.

## Known limitations

- **Trusted Publisher setup is manual.** The adopter must configure the trusted publisher on PyPI (project settings → publishing → add GitHub). Wrangle cannot automate this. The adoption docs must include this step.
- **TestPyPI requires separate trusted publisher config.** Publishing to TestPyPI for testing requires a separate trusted publisher on test.pypi.org.
- **Binary wheels (maturin, Cython) may need platform-specific runners.** The default `ubuntu-latest` runner only produces Linux wheels. Multi-platform wheels require a build matrix, which is out of scope for v0.2.
- **Private registries** may require tokens instead of Trusted Publishing. The `repository-url` input supports this, but token handling is not yet specified.
- **uv is young.** While mature enough for production, edge cases may exist. The standard PEP 517 fallback ensures the build action works without uv.

## Integration testing

The companion repo (`tomhennen/wrangle-test`) will need a Python fixture:

```
python/
├── pyproject.toml      # minimal project with hatchling backend
├── src/
│   └── example/
│       └── __init__.py
└── tests/
    └── test_example.py
```

The fixture should NOT publish to real PyPI. Set `publish: false` in the companion template's `test-python` job. Publishing is tested separately (manually or via TestPyPI).
