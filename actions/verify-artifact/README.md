# Wrangle Verify Artifact

Verify that the artifact bytes sitting on *this* runner match the SLSA provenance wrangle produced, before you publish them.

## Why

Wrangle's reusable workflow verifies provenance in its own `verify` job — but that job runs on a different runner against its own download of the dist. Your publish job downloads an independent copy via `actions/download-artifact`, so without a check of its own it has no machine-verified guarantee that the bytes it is about to `npm publish` / `twine upload` are the bytes wrangle built and attested. This action closes that gap: it runs `gh attestation verify` against your local files, on the runner that publishes them.

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

If verification fails, the job fails before any bytes leave the runner.

## Inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `path` | (required) | A file, or a directory — every file under it (recursive) is verified. |
| `signer-workflow` | any wrangle `build_and_publish_*` workflow | The reusable workflow bound as the provenance signer (`<owner>/<repo>/<path>.yml`). Set it to your build type's workflow for the tightest binding. |
| `repo` | `${{ github.repository }}` | Repository whose attestation store `gh` queries. |
| `github-token` | `${{ github.token }}` | Token for the attestation API. |

The job needs no extra permissions beyond `contents: read` (the default token fetches attestations with it).

## What it verifies — and what it doesn't

`gh attestation verify` fetches the provenance from GitHub's attestation store by the file's digest and checks, fail-closed: the digest matches a provenance subject, the Sigstore signature is valid, the source repository is `repo`, and the signing workflow is `signer-workflow`. Because wrangle's attest step runs inside its reusable workflow, that workflow is the Sigstore signer — which is why the binding names wrangle, not your caller workflow.

This action checks build provenance, not policy: the policy decision (ampel against the wrangle PolicySet, emitting the signed VSA) already gated your publish job via `needs:` inside the reusable workflow. Downstream consumers verify the published artifact themselves — see "Verifying after install" in your build type's README under [`build/actions/`](../../build/).
