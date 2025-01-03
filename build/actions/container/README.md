# Wrangle Build Container

A GitHub action that builds and publishes a container image following best practices.

This keeps build and publication together because that seems to be standard practice
for container images (even if it isn't ideal.)

TODO:

- See if we can split build and publication.
- Sign container image.
- Maybe we should just have this _always_ publish to the ghcr registry and then we can handle 'promotion' in another step.