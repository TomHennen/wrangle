# Wrangle Workflow Examples

Starting points for adopting wrangle. Copy to `.github/workflows/` in your repo and customize the inputs for your project.

**Pair any build/publish workflow with `check_source_change.yml`.** Build hardens *how* your artifact is produced; source scan covers *what was checked into the repo you're building from*. See [`../actions/scan/README.md`](../actions/scan/README.md) for the rationale.

| Workflow | What it does | Per-build-type README |
|----------|-------------|------------------------|
| `check_source_change.yml` | OSV-Scanner, Zizmor, Scorecard, dependency-review on every PR and push. | [`actions/scan/README.md`](../actions/scan/README.md) |
| `build_shell.yml` | shellcheck + bats. No artifact. | — |
| `build_and_publish_containers.yml` | Build, sign, publish a container image with SBOM and SLSA L3 provenance. | [`../build/actions/container/README.md`](../build/actions/container/README.md) |
| `build_npm.yml` | `npm pack` / `pnpm pack`, test, SBOM, SLSA L3 provenance. Publishes via npm Trusted Publishing — publish job stays in the caller workflow ([npm constraint](https://github.com/npm/documentation/issues/1755)). | [`../build/actions/npm/README.md`](../build/actions/npm/README.md) |
| `build_python.yml` | Wheel + sdist, pytest, SBOM, SLSA L3 provenance. Publishes via PyPI Trusted Publishing — publish job stays in the caller. | [`../build/actions/python/README.md`](../build/actions/python/README.md) |

The npm and python README "Before first use" sections walk through Trusted Publishing setup (bootstrap publish, disable token uploads). Roadmap: [#201](https://github.com/TomHennen/wrangle/issues/201) adds per-commit SLSA Source Track attestations to `check_source_change.yml`.
