# Wrangle Build Python

Wrangle builds your Python package (wheel + sdist), runs pytest, generates an SBOM, produces SLSA Build L3 provenance, and publishes to PyPI via Trusted Publishing — no API tokens in your repo. Your users get a signed VSA they can verify with one command.

One wrinkle is PyPI's, not wrangle's: the publish step must live in *your* workflow, because PyPI requires the OIDC token to come from the caller ([pypi/warehouse#11096](https://github.com/pypi/warehouse/issues/11096)). The example wires it — see [Your publish job](#your-publish-job).

## Quick start

Copy [`build_python.yml`](../../../gh_workflow_examples/build_python.yml) into `.github/workflows/`. It wires the permissions, the build call, and the publish job — most adopters only need to set `path`:

```yaml
jobs:
  build:
    permissions:
      contents: write         # verify attaches the VSA to the release on tags
      id-token: write         # Sigstore keyless signing
      attestations: write     # GitHub-issued SLSA provenance
      actions: read           # source scan
      security-events: write  # scan findings -> Security tab
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_python.yml@v0.2.0
    with:
      path: "."
      release-events: tag-only   # only tag pushes publish

  publish:
    # ... see the example: gates on should-release, verifies, then publishes
```

## Before first use

These steps set up [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/): CI publishes via OIDC, so no token ever lives in your repo. Already publishing this project via Trusted Publishing? Just point your trusted publisher at `build_python.yml` (step 1) and double-check step 2.

1. **Configure a Trusted Publisher on PyPI**, pinning your repo and the workflow filename (`build_python.yml`). Existing project: Project → Publishing → Add a trusted publisher. Brand-new package: use PyPI's [pending publisher](https://docs.pypi.org/trusted-publishers/creating-a-project-through-oidc/) flow — the first successful CI publish creates the project.
2. **Disable legacy API token uploads** (PyPI Publishing settings). A stolen or leftover token can push to the registry without ever touching your CI; this toggle closes that path, and only PyPI can flip it.
3. *(Optional)* Configure TestPyPI with its own Trusted Publisher for pre-release testing.

## What you get

- **uv or pip, auto-detected** — `uv.lock` selects uv; otherwise standard PEP 517 tooling (`pip` + `python -m build`).
- **pytest runs automatically** when `tests/`, `test/`, or `[tool.pytest.ini_options]` is present (default pytest discovery conventions).
- **Source scan** built in — vulnerable dependencies (OSV), unsafe workflow patterns (Zizmor), and more ([details](../../../actions/scan/README.md)); a load-bearing finding blocks publish.
- **An SPDX SBOM**, uploaded as a workflow artifact.
- **SLSA Build L3 provenance** ([the conditions behind the claim](../../../docs/SLSA_L3_AUDIT.md)), plus PEP 740 attestations on PyPI from the publish step.
- **A signed VSA** attached to the release on tag pushes, so downstream users can verify your dist files with one command.

## Your publish job

Publishing happens in your workflow, so two things there are load-bearing — both already wired in the example:

1. **Gate on `should-release`**, so you publish only on release events (wrangle can't enforce this from inside the reusable workflow):

   ```yaml
   publish:
     if: ${{ needs.build.outputs.should-release == 'true' }}
     needs: [build]
   ```

2. **Verify before you publish** — run wrangle's [`verify-vsa`](../../../actions/verify-vsa/README.md) action between `download-artifact` and the publish step, so the exact bytes leaving the runner are the bytes that passed wrangle's policy:

   ```yaml
   - uses: TomHennen/wrangle/actions/verify-vsa@v0.2.0
     with:
       path: dist/
       signer-workflow: TomHennen/wrangle/.github/workflows/build_and_publish_python.yml
   ```

Skip the gate and you publish on every non-PR event; skip verify-vsa and you may publish bytes wrangle's policy never blessed.

## Good to know

- **`release-events`** (default: `non-pull-request`; the example sets `tag-only`) controls when release-time actions run and what `should-release` reports — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating".
- **`pull_request_target` can't trigger this workflow** — that trigger (and `workflow_run` chained from it) is a common exploit vector, so wrangle blocks both at startup.
- **Workflow outputs** are documented in [`build_and_publish_python.yml`](../../../.github/workflows/build_and_publish_python.yml) itself.

## Verifying what you shipped

Downstream users verify a dist file with one command. Download the wheel (or sdist) and its VSA (`<dist-file>.intoto.jsonl`) from the release, then ([ampel](https://github.com/carabiner-dev/ampel) ≥ v1.3.0):

```bash
ampel verify --subject <dist-file> \
  --policy git+https://github.com/TomHennen/wrangle@v0.2.0#policies/wrangle-vsa-consumer-v1.hjson \
  --attestation <dist-file>.intoto.jsonl \
  --context expectedResourceUri:pkg:generic/<name>@<version> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

That single command checks — fail-closed — the signature, wrangle's signer identity, that the build ran in *your* repo, and that policy passed at SLSA Build L3. No ampel? See the [artifact verification guide](../../../docs/verifying_artifacts.md) for an equivalent cosign recipe, the PEP 740 path, and the full trust model.

## Further reading

- [`SPEC.md`](./SPEC.md) — this action's full specification: inputs, outputs, step sequence, security model.
- [`docs/verifying_artifacts.md`](../../../docs/verifying_artifacts.md) — consumer verification: ampel, cosign, `gh attestation verify`, PEP 740.
- [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) — the conditions behind the Build L3 claim, including the uv cache analysis.
- [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/) — the underlying publish mechanism.
