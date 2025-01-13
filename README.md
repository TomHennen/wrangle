# wrangle

Wrangle is a toy project where I try to figure out if we can easily
integrate best practices and all the various tools available for
users without them needing to know all the details.

NOTE: I've never really used GitHub for professional development
before, so this is a bit of a learning process too.

Alternate name: "streetlights"


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


- [GitHub Workflow Examples](gh_workflow_examples/README.md)
  - GitHub workflow examples that GitHub users can copy, paste, and tweak in their own repos to adopt wrangle.
- [build](build/README.md)
  - Integrations for managing building artifacts and any metadata related to those artifacts.
- [source](source/README.md)
  - Integrations for managing source code.  Currently limited to 'scans' which look for problems.
    Could be expanded to linting, formatting, etc in the future.
- [worfkflows](.github/workflows/README.md)
  - Reusable workflows that allow project owners to easily adopt best practices for managing their project.
