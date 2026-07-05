#!/usr/bin/env bats

# Unit test for lib/generate_sbom.sh's docker-independent guard. The dispatch +
# relocation behavior (running a curated SBOM image through run.sh and lifting
# its <tool>/ outputs to the metadata-dir root) needs a real container, so it is
# covered in test/image/test_run_image_dispatch.bats.

@test "generate_sbom: rejects wrong argument count" {
    run "$(pwd)/lib/generate_sbom.sh" "$(pwd)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}
