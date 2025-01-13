# Wrangle Build Container

A GitHub action that builds and publishes a container image following best practices.

This keeps build and publication together because that seems to be standard practice
for container images (even if it isn't ideal.)

TODO:

- See if we can split build and publication.
- Sign container image.
- Maybe we should just have this _always_ publish to the ghcr registry and then we can handle 'promotion' in another step.

## SBOM

The action generates an SBOM for the container that was built.

## Container Vulnerability Scanning

After building the container and generating the SBOM the action will scan the container (using the SBOM) for vulnerabilities.

If any vulnerabilities are found the build will be marked as 'failed' and the results displayed in the summary.

![Wrangle Build Container Summary showing vulns found by OSV](/assets/images/osv_sbom_summary.png)
