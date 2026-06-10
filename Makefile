.PHONY: all test lint shellcheck shellstyle workflowstyle bats zizmor integration bump-action-pins

# bash, not the default sh: the integration recipe sources lib/env.sh,
# whose `set -o pipefail` dash doesn't reliably support.
SHELL := /bin/bash

# The bats suites that need real binaries and network (skip_or_fail-gated).
# local_build_shell.yml passes the same list as build_shell.yml's bats-path;
# test/test_setup_integration.bats fails if the two drift.
INTEGRATION_BATS := tools/osv/test.bats policies/test.bats actions/verify/test_run_verify.bats actions/verify/test_validate_verify_inputs.bats test/consumer/verify_consumer_vsa.bats

# Default target
all: test

# Run all local checks
test: lint shellcheck shellstyle workflowstyle bats zizmor

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

# Lint all shell scripts
shellcheck:
	@echo "=== shellcheck ==="
	@SCRIPTS=$$(find . -name '*.sh' -not -path './.git/*' -not -path './.beads/*' -not -path './.claude/*'); \
	if [ -n "$$SCRIPTS" ]; then \
		echo $$SCRIPTS | xargs shellcheck -x --source-path=SCRIPTDIR; \
	else \
		echo "No shell scripts to check"; \
	fi

# Run bats tests
bats:
	@echo "=== bats ==="
	@bats test/ test/lib/ test/consumer/ test/integration/ tools/*/test.bats actions/*/*.bats build/actions/*/test.bats

# Non-hermetic: installs real tools (network, registries, Sigstore) via
# test/setup_integration.sh, then runs the integration bats suites. NOT in
# `test` — the default suite stays deterministic. Run via ./test.sh integration,
# which sets GOTMPDIR onto its cache volume; go refuses a nonexistent one,
# and creating it belongs to the harness that defines it, not the setup script.
integration:
	@echo "=== integration ==="
	@if [[ -n "$$GOTMPDIR" ]]; then mkdir -p "$$GOTMPDIR"; fi
	@source lib/env.sh && ./test/setup_integration.sh && bats $(INTEGRATION_BATS)

# Workflow security linting (matches tools/zizmor/action.yml's CI invocation).
# --no-online-audits keeps the test container offline-friendly; the
# online audits (e.g. unpinned-uses against the live registry) are
# exercised by the same upstream action in CI.
zizmor:
	@echo "=== zizmor ==="
	@zizmor --no-online-audits .github/workflows actions/ tools/ build/

# Bump every TomHennen/wrangle/...@<sha> ref in .github/workflows/ to current HEAD.
# Idempotent. See tools/bump_action_pins.sh and #165.
# Usage: make bump-action-pins             # bump to HEAD
#        make bump-action-pins SHA=<sha>   # bump to a specific SHA
bump-action-pins:
	@./tools/bump_action_pins.sh $(SHA)

# Update a binary-download tool's version and hardcoded checksum. Go-module
# tools (osv-scanner, cosign, ampel, bnd) are pinned in tools/go.mod and
# bumped by Dependabot instead.
# Usage: make update-tool TOOL=syft VERSION=1.2.3
update-tool:
	@echo "Tool version update helper — not yet implemented"
	@echo "Will download $(TOOL) $(VERSION), compute SHA-256, and patch tools/$(TOOL)/install.sh"
	@exit 1
