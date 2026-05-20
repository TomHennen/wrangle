# Wrangle Build

Build types live here. Each produces a signed artifact with an SBOM and SLSA provenance.

| Build type | README | Example workflow |
|-----------|--------|------------------|
| npm / pnpm | [`actions/npm/README.md`](actions/npm/README.md) | [`build_npm.yml`](/gh_workflow_examples/build_npm.yml) |
| Python (pip / uv) | [`actions/python/README.md`](actions/python/README.md) | [`build_python.yml`](/gh_workflow_examples/build_python.yml) |
| Container | [`actions/container/README.md`](actions/container/README.md) | [`build_and_publish_containers.yml`](/gh_workflow_examples/build_and_publish_containers.yml) |
| Shell | (no artifact — shellcheck + bats only) | [`build_shell.yml`](/gh_workflow_examples/build_shell.yml) |

## Build Track level

Every build type that produces an artifact (npm, pnpm, pip, uv, container) meets **SLSA v1.2 Build L3** when consumed through wrangle's reusable workflow on GitHub-hosted runners. Shell produces no artifact, so no Build Track level applies. Each build type's README states the conditions that narrow its claim; see [`docs/SPEC.md` §"Build Track level"](../docs/SPEC.md) and [`docs/SLSA_L3_AUDIT.md`](../docs/SLSA_L3_AUDIT.md) for the full analysis.

![Wrangle Build Container Summary showing vulns found by OSV](/assets/images/osv_sbom_summary.png)
