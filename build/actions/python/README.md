# Wrangle Build Python

Build a Python package (wheel + sdist), run pytest, generate an SBOM, and produce SLSA L3 provenance. Publishes to PyPI via Trusted Publishing — the publish job lives in the caller workflow because PyPI's OIDC token must come from the caller, not a reusable workflow ([pypi/warehouse#11096](https://github.com/pypi/warehouse/issues/11096)).

## Quick-start

Copy [`gh_workflow_examples/build_python.yml`](../../../gh_workflow_examples/build_python.yml) into your repo at `.github/workflows/`. The example wires the required permissions (`contents: write` for the SLSA generator's upload-assets job, `id-token: write` for Sigstore, `actions: read`) and includes the publish job with verify-before-publish. Most adopters only need to set the `path` input.

Pair with [source scan](../../../actions/scan/README.md) for source-side coverage. For the composite-only path (build + test + SBOM, you wire your own provenance and publish), `uses: TomHennen/wrangle/build/actions/python@v0.2.0`.

This README documents shipped behavior. For architecture and the full step sequence, see [`SPEC.md`](./SPEC.md).

## Before first use

1. **Configure a Trusted Publisher on PyPI.** Project → Publishing → Add a trusted publisher. Specify your GitHub repo, workflow filename (`build_python.yml`), and optionally an environment.
2. **Disable legacy API token uploads on PyPI** (same page). **A stolen or leftover token bypasses your CI entirely**: an attacker can `twine upload` directly to the registry without ever triggering your trusted workflow — the attack vector behind the December 2024 ultralytics and May 2026 mistralai / guardrails-ai compromises. Wrangle can't enforce this; the toggle lives in PyPI's settings.
3. **(Optional) Configure TestPyPI** with a separate Trusted Publisher for pre-release testing.

## Build Track level

Consumed through `build_and_publish_python.yml`, the build meets **SLSA v1.2 Build L3** — for both the pip and the uv sub-path. Two conditions narrow the claim:

- **Reusable consumption only.** Calling the composite directly forfeits the build-vs-sign job separation and is **not** a supported L3 path.
- **GitHub-hosted runners only.** Self-hosted runners invalidate the build-environment isolation L3 assumes.

On the uv sub-path, release builds disable `setup-uv`'s cache (uv doesn't re-verify cache hits — would violate SLSA's "Isolated" requirement); PR builds keep it for fast iteration. The pip sub-path uses no cross-build cache. Full analysis: [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) Finding 1.

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

`release-events` controls which events produce SLSA provenance. Shorthands: `non-pull-request` (default), `tag-only`, `main-and-tags`. A comma-separated `github.event_name` list (e.g., `push,workflow_dispatch`) is also accepted — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating".

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

## SLSA provenance verification (default-on, opt-out)

The reusable workflow verifies the just-built dist against the SLSA L3 provenance before declaring success — failure blocks your publish job via `needs:`. This catches tampering between wrangle's build and your publish, so your publish job stays as simple as `download-artifact` + `pypa/gh-action-pypi-publish`. Opt out with `verify-provenance: false` if you maintain a custom verification flow (the integrity guarantee then shifts to you).

## Verifying after install (downstream consumers)

Two complementary verification paths, different roots of trust:

**PEP 740 attestations (against PyPI).** PyPI stores Sigstore-based attestations alongside every wheel published with `attestations: true` (which `pypa/gh-action-pypi-publish` does). Proves *who published* — the GitHub workflow identity, recorded in Sigstore's transparency log. The wheel's PyPI page shows verification status; `sigstore-python` verifies on the command line.

> **Known limitation.** `pip install` does NOT verify PEP 740 attestations by default (experimental in pip 24.x). Until verification is the default, the load-bearing check is PyPI's upload-time `workflow_ref` validation — but that only holds when legacy token uploads are disabled (see "Before first use"), since a stolen token bypasses it entirely.

**SLSA L3 provenance (against your GitHub release).** Proves *how the artifact was built* — inputs, builder, materials. Non-falsifiable because the generator runs in an isolated reusable workflow. Wrangle attaches the bundle to the GitHub release on tag pushes (`python-<shortname>.intoto.jsonl`, where `<shortname>` is the path-derived name — `.` becomes `_`):

```bash
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/<package>-<version>-py3-none-any.whl"
curl -LO "https://github.com/<owner>/<repo>/releases/download/<tag>/python-<shortname>.intoto.jsonl"

slsa-verifier verify-artifact \
  --provenance-path python-<shortname>.intoto.jsonl \
  --source-uri "github.com/<owner>/<repo>" \
  <package>-<version>-py3-none-any.whl
```

> **Tag-push only.** On non-tag publishes (e.g., `workflow_dispatch` from a branch) the provenance lives only as a 90-day workflow artifact and isn't retrievable by external consumers. [#181](https://github.com/TomHennen/wrangle/issues/181) tracks moving to a single bundled `multiple.intoto.jsonl` at the release layer.

## What this action does

- Detects `uv` (presence of `uv.lock`) vs PEP 517 tooling and routes dependencies, build, and tests accordingly.
- Installs the project (`pip install -e ".[test]"` or `uv sync`).
- Runs `pytest` if `tests/`, `test/`, or `[tool.pytest.ini_options]` is present in `pyproject.toml`.
- Builds wheel + sdist (`python -m build` or `uv build`).
- Generates an SPDX SBOM via `syft` (Cosign-keyless-verified install).
- Computes SHA-256 hashes in the format `slsa-github-generator`'s `base64-subjects` expects.

## Outputs from the reusable workflow

- `dist-artifact-name` — workflow-artifact name for the wheel + sdist.
- `provenance-artifact-name` — workflow-artifact name for the SLSA provenance (`python-<shortname>.intoto.jsonl`; empty when `should-release` is false).
- `metadata-artifact-name` — workflow-artifact name for the SBOM (`python-metadata-<shortname>`).
- `should-release` — `"true"` if the event matches `release-events`. Your publish job MUST gate on this.
- `hashes`, `version`.

`<shortname>` is path-derived (`.` → `_`, `pkg/foo` → `pkg_foo`) so multiple python builds in one workflow don't collide on artifact names.

## SBOM

Written to `metadata/python/<shortname>/sbom.spdx.json` and uploaded as the `python-metadata-<shortname>` workflow artifact (exposed via the `metadata-artifact-name` output). Download lands the files at the top level of whatever `path:` you pick — the `metadata/python/<shortname>/` prefix is a workspace convention, not preserved in the zip. See [`docs/SPEC.md`](../../../docs/SPEC.md) "Unified metadata layout".

## Further reading

- [`SPEC.md`](./SPEC.md) — this action's full specification.
- [`../../../docs/SPEC.md`](../../../docs/SPEC.md) — wrangle's architecture.
- [`../../../actions/scan/README.md`](../../../actions/scan/README.md) — source-scan companion.
- [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/), [SLSA generic generator](https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/generic/README.md).
