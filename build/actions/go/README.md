# Wrangle Build Go

Wrangle wraps your existing `.goreleaser.yml` — it doesn't replace it. You keep your goreleaser config and everything it already does (Docker pushes, Homebrew taps, deb/rpm, announcements). Wrangle adds the security drudgery around it: gofmt/vet/test/govulncheck, an SPDX SBOM, SLSA Build L3 provenance, and a signed VSA your users can verify with one command.

## Quick start

Copy [`build_go.yml`](../../../gh_workflow_examples/build_go.yml) into `.github/workflows/` and set `path`:

```yaml
jobs:
  build:
    permissions:
      contents: write         # goreleaser creates the Release; verify attaches the VSA
      id-token: write         # Sigstore keyless signing
      attestations: write     # GitHub-issued SLSA provenance
      actions: read           # source scan
      security-events: write  # scan findings -> Security tab
    uses: TomHennen/wrangle/.github/workflows/build_and_publish_go.yml@v0.2.0
    with:
      path: "."
```

You also need a `.goreleaser.yml` at `<path>/.goreleaser.yml` — the minimum wrangle recommends (complete version in the [example config](../../../gh_workflow_examples/build_go.goreleaser.yml)):

```yaml
version: 2
builds:
  - main: ./cmd/<your-binary>
    flags: [-trimpath]             # zero-cost reproducibility win
checksum:
  name_template: "checksums.txt"   # the subject set wrangle attests
```

Push a `v`-prefixed semver tag (e.g. `v1.2.3`) and wrangle runs the full pipeline and publishes the release. PRs build and test without publishing.

## What you get

- **Source scan** built in — vulnerable dependencies (OSV), unsafe workflow patterns (Zizmor), and more ([details](../../../actions/scan/README.md)); a load-bearing finding blocks the release. No separate scan workflow needed.
- **Checks before bytes ship** — gofmt, `go vet`, `go test`, govulncheck run in a read-only job; a failure blocks the release job.
- **An SPDX SBOM**, uploaded as a workflow artifact.
- **SLSA Build L3 provenance** tying each artifact to the workflow that built it (consumed through the reusable workflow on GitHub-hosted runners — the conditions are in [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md)).
- **A signed VSA** attached to the release, so downstream users can verify your artifacts with one command.

## Good to know

- **Tags must be `v`-prefixed semver** — the workflow triggers on `tags: ["v*"]` and goreleaser derives `.Version` from the nearest matching tag. If your repo has no `v*` tags yet, a `snapshot.version_template` that calls `incpatch`/`incminor`/`incmajor` fails; use the snapshot template from the [example config](../../../gh_workflow_examples/build_go.goreleaser.yml), which works regardless of tag history.
- **Provenance covers what's in `checksums.txt`** — archives, deb/rpm/apk/snap packages, and the checksum file itself. Docker images and Homebrew taps goreleaser pushes are *not* covered; pair with wrangle's [container build type](../container/README.md) for images.
- **`release-events`** (default: `tag-only`) controls which events run the full pipeline — see [`docs/SPEC.md`](../../../docs/SPEC.md) "Release-events gating". `tag-only` is the cheapest setting; use `non-pull-request` if you want main/dispatch builds to exercise the pipeline early.
- **Workflow outputs** (`dist-artifact-name`, `provenance-artifact-name`, `metadata-artifact-name`, `hashes`, `version`, `should-release`) are documented in [`build_and_publish_go.yml`](../../../.github/workflows/build_and_publish_go.yml) itself.

## Cross-compiling with cgo

The runner's C toolchain is amd64-only, so `CGO_ENABLED=1` plus a non-`linux/amd64` target fails with opaque `# runtime/cgo` assembler errors. What to do:

| Situation | Fix |
|---|---|
| You don't actually use cgo (most projects) | Set `CGO_ENABLED=0` in `builds.env` — Go cross-compiles freely without cgo. |
| cgo, but only linux/amd64 | Restrict `goos: [linux]`, `goarch: [amd64]` — the runner's native gcc handles it. |
| cgo + multi-arch / darwin | Pass `install-zig: true` and set `CC=zig cc -target <triple>` per build — working config in the [cgo example](../../../gh_workflow_examples/build_go_cgo.goreleaser.yml). |
| cgo + another toolchain (musl-gcc, mingw) | Install it in `before.hooks` and set `CC=`/`CXX=` yourself; leave `install-zig` unset. |

## Verifying what you shipped

Downstream users verify a release archive with one command. Download the archive and its VSA (`<archive>.intoto.jsonl`) from the release, then ([ampel](https://github.com/carabiner-dev/ampel) ≥ v1.3.0):

```bash
ampel verify --subject <archive> \
  --policy git+https://github.com/TomHennen/wrangle@v0.2.0#policies/wrangle-vsa-consumer-v1.hjson \
  --attestation <archive>.intoto.jsonl \
  --context expectedResourceUri:pkg:golang/<module-path>@<version> \
  --context sourceRepo:https://github.com/<your-org>/<your-repo>
```

That single command checks — fail-closed — the signature, wrangle's signer identity, that the build ran in *your* repo, and that policy passed at SLSA Build L3. The module path is the `module` directive in your `go.mod`; the policy locator can pin any wrangle `v*` tag. No ampel? An equivalent cosign recipe — and the full trust model — is in the [artifact verification guide](../../../docs/verifying_artifacts.md).

## Further reading

- [`SPEC.md`](./SPEC.md) — design rationale: tool choices, permissions architecture, cache isolation.
- [`docs/verifying_artifacts.md`](../../../docs/verifying_artifacts.md) — consumer verification: ampel, cosign, `gh attestation verify`, and the publish/attest timing model.
- [`docs/SLSA_L3_AUDIT.md`](../../../docs/SLSA_L3_AUDIT.md) — the conditions behind the Build L3 claim.
- [goreleaser customization](https://goreleaser.com/customization/) — the underlying build tool.
