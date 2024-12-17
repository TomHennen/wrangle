Builds all containers that match /src/CONTAINER_NAME/Dockerfile

Outputs the container as a tar file in /dist/CONTAINER_NAME.tar
Outputs the SBOM into /metadata

Expects
  - /src to be mounted readonly
  - /dist to be mounted readwrite
  - /metadata to be mounted readwrite
  - docker.sock to be mapped. e.g. `-v /var/run/docker.sock:/var/run/docker.sock`

Notes:
  - Does not produce 'provenance' since we want that produced by the builder.
  - You can imagine wanting a version of this tool that doesn't produce an SBOM
    to speed things up.