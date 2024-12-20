#!/bin/sh
set -e

echo "osv"

WRANGLE_EXIT_STATUS=0

# Run a scan over all of source and ignore errors, because OSV likes to fail
# too often. :) (Maybe it generates an error code when it finds problems?)
/osv-scanner --format sarif --output /metadata/osv.sarif -r /src || echo "osv failure when generating sarif"; WRANGLE_EXIT_STATUS=1
# Run it again for the markdown. (if only we could output in multiple formats from one run...)
/osv-scanner --format markdown --output /metadata/osv.md -r /src || echo "osv failure when generating markdown"; WRANGLE_EXIT_STATUS=1
cat /metadata/osv.md
exit $WRANGLE_EXIT_STATUS