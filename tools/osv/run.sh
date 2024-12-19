#!/bin/sh
set -e

echo "osv"
# Run a scan over all of source and ignore errors, because OSV likes to fail
# too often. :) (Maybe it generates an error code when it finds problems?)
/osv-scanner --format sarif --output /metadata/osv.sarif -r /src || true
# Run it again for the markdown. (if only we could output in multiple formats from one run...)
/osv-scanner --format markdown --output /metadata/osv.md -r /src || true
