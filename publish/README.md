# Wrangle Publish

This folder contains all the tools and actions for dealing with publication.

For now it just includes container publication.

## GitHub Actions Example

To build and publish a container image using Wrangle, all you have to do is add
this snippet (with appropriate modifications) to your corresponding GitHub Action
workflow.

```yaml
jobs:
  build-and-publish:
    permissions:
      contents: read
      actions: read # for detecting the Github Actions environment.
      id-token: write # for creating OIDC tokens for signing.
      packages: write # for uploading attestations.
    uses: tomhennen/wrangle/.github/workflows/build_and_publish_container.yml@main
    with:
      path: PATH/TO/FOLDER/WITH/Dockerfile
      imagename: ghcr.io/${{ github.repository }}/YOUR_IMAGE_NAME
      registry: 'ghcr.io'
    secrets:
      gh_token: ${{ secrets.GITHUB_TOKEN }}
```

See the [full example here](/gh_workflow_examples/build_and_publish_containers.yml).

## Next

- Generate SBOMs
- Document how inputs and metadata should be handled by tooling.
