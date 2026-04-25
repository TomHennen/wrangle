# Wrangle Workflow Examples

Starting points for adopting wrangle. Copy to `.github/workflows/` in your repo and customize the inputs (paths, image names, etc.) for your project.

## check_source_change.yml

Run OSV, Zizmor, and Scorecard source scanning on every PR and push.

## build_shell.yml

Run shellcheck and bats tests on shell projects.

## build_and_publish_containers.yml

Build, sign, and publish a container image with SBOM and SLSA L3 provenance.

## build_python.yml

Build a Python package (wheel + sdist), run pytest, generate an SPDX SBOM, and produce SLSA L3 build provenance. Optionally verify the provenance with `slsa-verifier` before publishing to PyPI via Trusted Publishing (no API tokens). Adopters must configure a [Trusted Publisher on PyPI](https://docs.pypi.org/trusted-publishers/) before the first publish — see [`build/actions/python/README.md`](/build/actions/python/README.md) for the onboarding checklist.
