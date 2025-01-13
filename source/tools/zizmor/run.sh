#!/bin/bash
set -e

WRANGLE_EXIT_STATUS=0
NO_COLOR=1

echo "Generate sarif"
/usr/local/cargo/bin/zizmor --format sarif -o `find /src/.github/workflows -name "*.yml"` > /metadata/output.sarif || WRANGLE_EXIT_STATUS=1
# Run it again for the plain output. (if only we could output in multiple formats from one run...)
echo "Generate plain"
/usr/local/cargo/bin/zizmor --format plain -o `find /src/.github/workflows -name "*.yml"` > /metadata/output.txt || WRANGLE_EXIT_STATUS=1

# zizmor sarif generation doesn't set exit codes if there are problems, but plain does.
# let's hedge our bets and set the exit status manually based on sarif results.
kind_fail=$(jq 'any(.runs[].results[].kind; contains("fail"))' /metadata/output.sarif)
if [ "$kind_fail" = "true" ]; then
    WRANGLE_EXIT_STATUS=1
fi

exit $WRANGLE_EXIT_STATUS
