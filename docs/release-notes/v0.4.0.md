## wrangle v0.4.0

Private repos and immutable releases can now complete a release — two places wrangle previously couldn't finish at all. Shell builds are roughly **2× faster**. Pin the reusable workflows at `@v0.4.0`.

**Breaking:** the `go-cache` input is gone — remove it from your workflow calls, or they'll fail with an unknown-input error. It cached nothing once the scan tools moved to containers.

### Your private repo can release now

The release path used to die on a private repo: `attest` failed, `verify` never ran, nothing was published, and there was no way to turn it off.

Set **`attest-and-verify: disabled`** and you get a normal release — built, tested, scanned, same gates — published **unattested** and marked as such. The default (`enabled`) is unchanged on public repos; on a private one wrangle now **fails fast in the first job** with a message telling you what to do, instead of dying mid-build on a raw API error.

It isn't automatic because attestation genuinely can't work there, for two different reasons:

- **Private personal repo** — GitHub's attestation store **doesn't support it**. It would simply fail.
- **Private org repo** — wrangle signs keyless to public-good Sigstore, so the certificate lands in the **public Rekor transparency log**, permanently leaking the repo's identity and build timing.

Full private-repo attestation is tracked in [#600](https://github.com/TomHennen/wrangle/issues/600).

### Immutable releases work

wrangle used to publish the release, *then* upload the signed bundles — which a frozen release rejects. It now creates a **draft**, attaches everything, and publishes as the last step. Nothing to configure.

### Faster builds

The shell build dropped from **~6 minutes to ~2m50s** (warm) — tool images are pre-built concurrently into a layer cache, and the test-harness setup no longer rebuilds per test. Want more: set **`bats-jobs: <n>`** to run test files concurrently (default `1`; raise it only if your suite shares no cross-file state).

### Coming from v0.3.0?

v0.3.1 was quiet, so you also get: **scan and SBOM tools running as digest-pinned OCI images that wrangle verifies before running** (fails closed if an image doesn't verify), and **bring-your-own SBOM tool** via `.wrangle/tools.json` + `sbom-tool: <name>`, sandboxed and attested like the built-ins.

### Check the evidence yourself

Every artifact carries a signed attestation you can verify with `gh attestation verify`, `cosign`, or `ampel`; the curated tool images carry their own SLSA-L3 provenance. Recipe: [docs/verifying_artifacts.md](https://github.com/TomHennen/wrangle/blob/v0.4.0/docs/verifying_artifacts.md). Your VSAs now name **wrangle** as the verifier, not the underlying policy engine.

Signing is also more reliable: wrangle used to open a fresh Sigstore session per artifact (a six-artifact release meant six OIDC/TUF/certificate handshakes, any of which could fail transiently). It now does one per job.
