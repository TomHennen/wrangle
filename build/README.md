# Wrangle Build

This folder contains all the tools and actions for dealing with building packages.

Wrangle will have customized build methods for each supported artifact type/destination.

Currently supported build types:
- **Containers** — see below.
- **Python** — see [`actions/python/README.md`](actions/python/README.md).
- **Shell** — see the [example workflow](/gh_workflow_examples/build_shell.yml).

## Containers with GitHub Actions

### User Instructions

Wrangle supports building containers with GitHub actions in two ways:

* A reusable workflow that handles everything, SBOM generation, vuln scanning, and provenance generation. [Example](/gh_workflow_examples/build_and_publish_containers.yml)
* An [action](/build/actions/container/action.yml) that you can plug into your existing workflow.  Handles SBOM generation and vuln scanning.

Example vulnerability scan results:
![Wrangle Build Container Summary showing vulns found by OSV](/assets/images/osv_sbom_summary.png)

## Python with GitHub Actions

Build Python wheels and sdists, run pytest, generate an SPDX SBOM, and produce SLSA L3 provenance via `slsa-github-generator`. Publish to PyPI via Trusted Publishing (no API tokens required) with PEP 740 attestations.

* A reusable workflow that runs build + test + SBOM + SLSA provenance. [Example](/gh_workflow_examples/build_python.yml)
* The composite [action](/build/actions/python/action.yml) for plugging into existing workflows (build + test + SBOM only).

The example workflow demonstrates the recommended pattern of verifying SLSA provenance before publish — adopters can keep or remove that step. See [`actions/python/README.md`](actions/python/README.md) for full details.
