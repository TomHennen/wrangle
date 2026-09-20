#!/usr/bin/env bats

# release.yml is the only workflow that can create an immutable tag. The human
# gate is `environment: release` on the tag job and nowhere else, and the write
# scopes it hands out are the blast radius of a mistake — both are worth failing
# loudly over, because neither is caught by actionlint or zizmor.

setup() {
    WORKFLOW="$BATS_TEST_DIRNAME/../.github/workflows/release.yml"
}

# Everything indented under `  <job>:`, up to the next job.
job_block() {
    awk -v job="  $1:" '
        $0 == job { inblock = 1; next }
        inblock && /^  [^ ]/ { inblock = 0 }
        inblock { print }
    ' "$WORKFLOW"
}

count() { grep -c "$1" "$WORKFLOW" || true; }

@test "release.yml gates the tag job, and only the tag job, on the release environment" {
    [[ "$(count 'environment: release')" -eq 1 ]]
    job_block tag | grep -q 'environment: release'
}

@test "release.yml grants contents: write only to the tag job" {
    [[ "$(count 'contents: write')" -eq 1 ]]
    job_block tag | grep -q 'contents: write'
}

@test "release.yml grants issues: write only to the alert job" {
    [[ "$(count 'issues: write')" -eq 1 ]]
    job_block alert | grep -q 'issues: write'
}

@test "release.yml grants no workflow-level permissions" {
    grep -q '^permissions: {}' "$WORKFLOW"
}
