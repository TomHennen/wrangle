# Wrangle Verify VSA

Verify that the artifact bytes sitting on *this* runner carry a signed, PASSED wrangle VSA, before you publish them.

## Why

Wrangle's reusable workflow evaluates policy in its own `verify` job — but that job runs on a different runner against its own download of the dist. Your publish job downloads an independent copy via `actions/download-artifact`, so without a check of its own it has no machine-verified guarantee that the bytes it is about to `npm publish` / `twine upload` are the bytes that passed policy. This action closes that gap on the runner that publishes.

It verifies the **VSA**, not the raw provenance, on purpose: the VSA is the artifact's full policy verdict — provenance *plus every other tenet the wrangle PolicySet checks* (as the policy grows to cover scanner results, SBOM presence, etc., this gate inherits those checks automatically). The check is `ampel verify` against [`wrangle-vsa-consumer-v1`](../../policies/wrangle-vsa-consumer-v1.hjson) — the same one-command verification downstream consumers run.

## Usage

Drop it into your publish job between `download-artifact` and the publish step:

```yaml
- uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
  with:
    name: ${{ needs.build.outputs.dist-artifact-name }}
    path: dist/

- uses: TomHennen/wrangle/actions/verify-vsa@1448b250fb8d75841dfba3b2c8f5c23e85162b89 # v0.2.0
  with:
    path: dist/
    resource-uri: ${{ needs.build.outputs.resource-uri }}

- run: npm publish ...
```

If any file lacks a VSA, the signature or identity doesn't check out, or the verdict isn't PASSED, the job fails before any bytes leave the runner. (A combined variant that also performs the dist download is under consideration — [#352](https://github.com/TomHennen/wrangle/issues/352).)

## Inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `path` | (required) | A file, or a directory — every file under it (recursive) is verified. |
| `resource-uri` | (required) | The resource the VSA must name (its `resourceUri`) — pipe the build workflow's `resource-uri` output. |
| `repo` | `${{ github.repository }}` | Origin repository the VSA's signer must have been running in. |

No extra permissions are needed: the action reads the VSAs from this run's workflow artifacts (where wrangle's verify job uploaded them, one per dist file, named `<artifact-basename>.intoto.jsonl`).

## What it verifies — and what it doesn't

For each file, fail-closed:

- the file's hash matches the VSA's subject — these exact bytes are what passed policy;
- the VSA's signature is valid and was signed by one of wrangle's reusable `build_and_publish_*` workflows;
- that workflow was running in *your* repository (`repo`) — a wrangle-signed VSA from someone else's repo is rejected;
- the VSA names the resource you expect to publish (`resource-uri`);
- the verdict is `PASSED`, at SLSA Build L3.

Known gaps and scope limits:

- **It does not re-run policy.** Wrangle's `verify` job already evaluated the PolicySet; the VSA is that decision, signed. This action checks that the decision covers these bytes and says PASSED.
- **The signer binding accepts any ref** of wrangle's workflows (your build job already pins wrangle's ref; a tag-pinned binding would break SHA- and branch-pinned callers).
- **File blobs only, for now.** Container images have an image digest as their VSA subject, not a file, and are pushed from inside wrangle's reusable workflow rather than from an adopter publish job — so the container path verifies its VSA against the registry instead (see the [container README](../../build/actions/container/README.md)). Direct container support is tracked in [#353](https://github.com/TomHennen/wrangle/issues/353).

## Who can use it

- **Adopters' publish jobs** — the primary audience, as in the usage snippet above.
- **Any other job in the same workflow run** that handles the dist (a staging or smoke-test job) can use it the same way.
- **Downstream consumers of your published package can't** — the action reads same-run workflow artifacts, which don't exist outside the run. Consumers verify the same VSA with the commands in "Verifying after install" in your build type's README under [`build/actions/`](../../build/).
