# Wrangle Source

This folder contains all the tools and actions for dealing with source.

For now it just includes source scanning integrations.

## GitHub Actions Example

To scan your source code for issues using Wrangle, all you have to do is add this snippet
(with appropriate modifications) to your corresponding GitHub Action workflow.

```yaml
jobs:
  check-change:
    permissions:
      actions: read
      contents: read
      packages: read
      issues: read
      pull-requests: read
      security-events: write # So we can upload sarif
      statuses: read
    uses: tomhennen/wrangle/.github/workflows/check_source_change.yml@main
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
```

See the [full example here](../gh_workflow_examples/check_source_change.yml).

## Next

- Document how inputs and metadata should be handled by tooling.
