# wrangle

Wrangle is a toy project where I try to figure out if we can easily
integrate best practices and all the various tools available for
users without them needing to know all the details.

NOTE: I've never really used GitHub for professional development
before, so this is a bit of a learning process too.

## Quick Start

Add source scanning to any GitHub repo — create `.github/workflows/check_source_change.yml`:

```yaml
name: Check Source Change
on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["**"]

jobs:
  check-change:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: TomHennen/wrangle/.github/workflows/check_source_change.yml@v0.1.0
```

This runs OSV-Scanner, Zizmor, and OSSF Scorecard on every PR. Results appear in the Actions step summary and the Security tab.

For shell and container build types, see the [workflow examples](gh_workflow_examples/README.md).

## Goals

### Project Owners

Project owners should be able to easily find the documentation and tools for how they can write, build, and publish their software easily.

Once adopted project owners should get, for free, industry leading best practices for how software should be developed within that ecosystem.

Project owners should be able to focus, exclusively, on the features they want to develop for their project.  They should not have to worry
about the various details of the tooling used under the hood unless they really want to.

### Security Folks

Security professionals should be able to easily tweak existing tools and integrations and add new tools to Wrangle. These tools should then
be adopted transparently by all of Wrangle's users without those users needing to take any action beyond bumping their integrations to the
next version of Wrangle.

## Pieces

Wrangle is composed of a few pieces:


- [Workflow examples](gh_workflow_examples/README.md) — starter workflows for adopting wrangle
- [Reusable workflows](.github/workflows/README.md) — the workflows adopters call via `uses:`
- [Composite actions](actions/) — scan orchestration and tool wrappers
- [Build actions](build/) — build types (shell, container)
- [Spec](docs/SPEC.md) — architecture, contracts, and security model
