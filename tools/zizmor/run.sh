#!/bin/sh
set -e

echo "zizmor"
/usr/local/cargo/bin/zizmor --format sarif -o `find /src/ -name "*.yml"` > /metadata/zizmor.sarif
