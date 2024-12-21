#!/bin/sh
set -e

WRANGLE_EXIT_STATUS=0
NO_COLOR=1

echo "zizmor sarif"
/usr/local/cargo/bin/zizmor --format sarif -o `find /src/.github/workflows -name "*.yml"` > /metadata/zizmor.sarif || WRANGLE_EXIT_STATUS=1
# Run it again for the plain output. (if only we could output in multiple formats from one run...)
echo "zizmor plain"
/usr/local/cargo/bin/zizmor --format plain -o `find /src/.github/workflows -name "*.yml"` > /metadata/zizmor.txt || WRANGLE_EXIT_STATUS=1

cat /metadata/zizmor.txt

exit $WRANGLE_EXIT_STATUS
