# Wrangle Build

This folder contains all the tools and actions for dealing with building packages.

Wrangle will have customized build methods for each supported artifact type/destination.

For now Wrangle only supports building containers.

## Containers with GitHub Actions

### User Instructions

Wrangle supports building containers with GitHub actions in two ways:

* A reusable workflow that handles everything, SBOM generation, vuln scanning, and provenance generation. [Example](/gh_workflow_examples/build_and_publish_containers.yml)
* An [action](/build/actions/container/action.yml) that you can plug into your existing workflow.  Handles SBOM generation and vuln scanning.

Example vulnerability scan results:
![Wrangle Build Container Summary showing vulns found by OSV](/assets/images/osv_sbom_summary.png)
