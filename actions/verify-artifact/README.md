# Wrangle Verify Artifact

Verify that the artifact bytes sitting on *this* runner carry a signed, PASSED wrangle VSA, before you publish them.

## Why

Wrangle's reusable workflow evaluates policy in its own `verify` job — but that job runs on a different runner against its own download of the dist. Your publish job downloads an independent copy via `actions/download-artifact`, so without a check of its own it has no machine-verified guarantee that the bytes it is about to `npm publish` / `twine upload` are the bytes that passed policy. This action closes that gap on the runner that publishes.

It verifies the **VSA**, not the raw provenance, on purpose: the VSA is the artifact's full policy verdict — provenance *plus every other tenet the wrangle PolicySet checks* (as the policy grows to cover scanner results, SBOM presence, etc., this gate inherits those checks automatically). It is also the same statement wrangle tells downstream consumers to trust, so the publish job runs the exact check the integration suite regression-tests (`test/consumer/`).

## Usage

Drop it into your publish job between `download-artifact` and the publish step:

```yaml
- uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
  with:
    name: ${{ needs.build.outputs.dist-artifact-name }}
    path: dist/

- uses: TomHennen/wrangle/actions/verify-artifact@v0.2.0
  with:
    path: dist/
    signer-workflow: TomHennen/wrangle/.github/workflows/build_and_publish_npm.yml

- run: npm publish ...
```

If any file lacks a VSA, the signature or identity doesn't check out, or the verdict isn't PASSED, the job fails before any bytes leave the runner.

## Inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `path` | (required) | A file, or a directory — every file under it (recursive) is verified. |
| `signer-workflow` | any wrangle `build_and_publish_*` workflow | The reusable workflow bound as the VSA's keyless signer (`<owner>/<repo>/<path>.yml`). Set it to your build type's workflow for the tightest binding. |
| `repo` | `${{ github.repository }}` | Origin repository the signing certificate must name (`--certificate-github-workflow-repository`). |
| `vsa-path` | (auto-download) | Directory already holding the `<artifact-basename>.intoto.jsonl` files, if you downloaded them yourself. |

No extra permissions are needed: VSAs are fetched as same-run workflow artifacts, and cosign's keyless verification talks to Sigstore, not the GitHub API.

## What it verifies — and what it doesn't

Per file, `cosign verify-blob-attestation` checks fail-closed: the file's hash matches the VSA subject, the Sigstore signature is valid, the signer is wrangle's reusable workflow, and the signing certificate's origin repository is `repo`. cosign doesn't read predicate fields, so the action then decodes the DSSE payload and requires `verificationResult == "PASSED"`.

It does not re-run policy — ampel already did that in wrangle's `verify` job; the VSA is that decision, signed. Downstream consumers (people who install your published package) verify the same VSA themselves — see "Verifying after install" in your build type's README under [`build/actions/`](../../build/).
