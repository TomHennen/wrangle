#!/bin/sh
set -e

WRANGLE_EXIT_STATUS=0

# Run a scan over all of source and ignore errors, because OSV likes to fail
# too often. :) (Maybe it generates an error code when it finds problems?)
echo "osv sarif"
/osv-scanner --format sarif --output /metadata/osv.sarif -r /src || WRANGLE_EXIT_STATUS=1
# Run it again for the markdown. (if only we could output in multiple formats from one run...)
echo "osv markdown"
/osv-scanner --format markdown --output /metadata/osv.md -r /src || WRANGLE_EXIT_STATUS=1

cat /metadata/osv.md

exit $WRANGLE_EXIT_STATUS
