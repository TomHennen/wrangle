# Wrangle Workflow Examples

Copy these files to `.github/workflows/` in your repo to adopt wrangle.

## check_source_change.yml

Run OSV, Zizmor, and Scorecard source scanning on every PR and push.

## build_shell.yml

Run shellcheck and bats tests on shell projects.

## build_and_publish_containers.yml

Build, sign, and publish a container image with SBOM and SLSA L3 provenance.
