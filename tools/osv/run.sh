#!/bin/sh
set -e

echo "osv"
# Run a scan over all of source and ignore errors, because OSV likes to fail
# too often. :) (Maybe it generates an error code when it finds problems?)
/osv-scanner --format sarif --output /metadata/osv.json -r /src || true
