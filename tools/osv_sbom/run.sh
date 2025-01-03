#!/bin/sh
set -e

# We expect the only parameter to this script to be the path to the SBOM.

WRANGLE_EXIT_STATUS=0

# Run a scan over all of source and ignore errors, because OSV likes to fail
# too often. :) (Maybe it generates an error code when it finds problems?)
echo "Generate sarif"
/osv-scanner --format sarif --output /metadata/output.sarif --sbom $1 || WRANGLE_EXIT_STATUS=1
# Run it again for the markdown. (if only we could output in multiple formats from one run...)
echo "Generate markdown"
/osv-scanner --format markdown --output /metadata/output.md --sbom $1 || WRANGLE_EXIT_STATUS=1

exit $WRANGLE_EXIT_STATUS
