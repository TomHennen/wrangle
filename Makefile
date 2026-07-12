.PHONY: all test lint shellcheck shellstyle workflowstyle gotest bats zizmor integration bump-action-pins converge-action-pins check-catalog check-catalog-freshness check-catalog-provenance-freshness bump-catalog-digest bump-catalog-to-latest release-preflight

# bash, not the default sh: the integration recipe sources lib/env.sh,
# whose `set -o pipefail` dash doesn't reliably support.
SHELL := /bin/bash

# The bats suites that need real binaries and network (skip_or_fail-gated).
# Local-only convenience subset for `./test.sh integration`; CI runs every
# .bats via the dogfooded shell build's auto-detect (local_build_shell.yml).
INTEGRATION_BATS := tools/osv/test.bats policies/test.bats actions/verify/test_run_verify.bats actions/verify/test_validate_verify_inputs.bats test/consumer/verify_consumer_vsa.bats test/consumer/verify_consumer_provenance.bats

# Default target
all: test

# Run all local checks
test: lint shellcheck shellstyle workflowstyle gotest bats zizmor

# Validate all workflow and action YAML files
lint:
	@echo "=== actionlint ==="
	@actionlint

# Run wrangle-specific shell style linter (CLAUDE.md rules not covered by shellcheck)
shellstyle:
	@echo "=== wrangle-shell-lint ==="
	@./tools/wrangle-shell-lint/lint.sh

# Run wrangle-specific workflow style linter (CLAUDE.md GitHub Actions rules:
# run-block length, expression injection, continue-on-error justification)
workflowstyle:
	@echo "=== wrangle-workflow-lint ==="
	@./tools/wrangle-workflow-lint/lint.sh

# Run first-party Go unit tests (the wrangle-lint rule engine and the
# wrangle-attest attestation engine).
gotest:
	@echo "=== go test ==="
	@go -C tools test ./wrangle-lint/... ./wrangle-attest/...

# Lint all shell scripts (.sh and .bats) via the same script CI's dogfooded
# shell build runs, so the local and CI shellcheck surfaces can't drift (#368).
shellcheck:
	@./build/actions/shell/run_shellcheck.sh .

# Run bats tests. Fan out across files with GNU parallel (#530); within-file
# order is preserved so a file's setup assumptions hold. Falls back to serial
# when parallel is absent, so a host without it still runs the suite.
# test/consumer/ is NOT here: those suites need real ampel/cosign, so they are
# integration tests (in INTEGRATION_BATS + the dogfooded shell-build auto-detect)
# — kept out of this hermetic suite, which can't provide the tools and would
# silently skip them (the container test job can't see it's in CI to fail-hard).
BATS_JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
BATS_PARALLEL ?= $(if $(filter-out 0 1,$(BATS_JOBS)),$(if $(shell command -v parallel 2>/dev/null),--jobs $(BATS_JOBS) --no-parallelize-within-files))
bats:
	@echo "=== bats ==="
	@bats $(BATS_PARALLEL) test/ test/lib/ test/integration/ tools/*/test.bats actions/*/*.bats build/actions/*/test.bats

# Non-hermetic: installs real tools (network, registries, Sigstore) via
# test/setup_integration.sh, then runs the integration bats suites. NOT in
# `test` — the default suite stays deterministic. Run via ./test.sh integration,
# which sets GOTMPDIR onto its cache volume; go refuses a nonexistent one,
# and creating it belongs to the harness that defines it, not the setup script.
integration:
	@echo "=== integration ==="
	@if [[ -n "$$GOTMPDIR" ]]; then mkdir -p "$$GOTMPDIR"; fi
	@source lib/env.sh && ./test/setup_integration.sh && bats $(BATS_PARALLEL) $(INTEGRATION_BATS)

# Workflow security linting against the wrangle repo itself.
# --no-online-audits keeps the test container offline-friendly; the audits
# that need network (e.g. known-vulnerable-actions against the GitHub
# Advisories DB) are exercised by the zizmor tool image in CI. unpinned-uses
# works offline, so this run does enforce SHA-pinning locally.
zizmor:
	@echo "=== zizmor ==="
	@zizmor --no-online-audits .github/workflows actions/ tools/ build/

# Bump every TomHennen/wrangle/...@<sha> ref in .github/workflows/ to current HEAD.
# Idempotent. See tools/bump_action_pins.sh and #165.
# Usage: make bump-action-pins             # bump to HEAD
#        make bump-action-pins SHA=<sha>   # bump to a specific SHA
bump-action-pins:
	@./tools/bump_action_pins.sh $(SHA)

# Loop bump + commit until the nested pin chain is both reachable and fresh
# (check_pin_ancestry + check_pin_freshness green; a nested chain needs one
# commit per level). Land the result as a merge commit, not a squash.
# See tools/converge_action_pins.sh, #539, and #552.
converge-action-pins:
	@./tools/converge_action_pins.sh

# Static, network-free catalog validator (digest-pinned, on-namespace, capability
# enum). Runs every PR; see tools/check_catalog.sh.
check-catalog:
	@./tools/check_catalog.sh

# Adoption-lag freshness check: compares each curated image digest against its
# :latest tag in the registry (network). A release precondition, not a per-PR
# gate. See tools/check_catalog_freshness.sh.
check-catalog-freshness:
	@./tools/check_catalog_freshness.sh

# Provenance source-freshness: fails if a pinned image's build commit differs
# from HEAD's tool source (network + full git history). A release precondition,
# not a per-PR gate. See tools/check_catalog_provenance_freshness.sh.
check-catalog-provenance-freshness:
	@./tools/check_catalog_provenance_freshness.sh

# One-command fix when check-catalog-freshness reports drift.
# Usage: make bump-catalog-digest TOOL=osv DIGEST=sha256:<64hex>
bump-catalog-digest:
	@./tools/bump_catalog_digest.sh $(TOOL) $(DIGEST)

# Repoint every curated entry to its current registry :latest digest (the batch
# driver the post-publish auto-bump runs). See tools/bump_catalog_to_latest.sh.
bump-catalog-to-latest:
	@./tools/bump_catalog_to_latest.sh

# Every code-level gate that must hold before a release tag is cut. The tag is
# immutable, so this runs before `gh release create`, not after.
release-preflight:
	@./tools/release_preflight.sh
