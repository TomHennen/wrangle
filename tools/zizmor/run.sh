#!/bin/sh
set -e

echo "zizmor"
NO_COLOR=1
echo "zizmor sarif"
/usr/local/cargo/bin/zizmor --format sarif -o `find /src/.github/workflows -name "*.yml"` > /metadata/zizmor.sarif || true
# Run it again for the plain output. (if only we could output in multiple formats from one run...)
echo "zizmor plain"
/usr/local/cargo/bin/zizmor --format plain -o `find /src/.github/workflows -name "*.yml"` > /metadata/zizmor.txt || true
cat /metadata/zizmor.txt