.PHONY: all test lint shellcheck bats

# Default target
all: test

# Run all local checks
test: lint shellcheck bats

# Validate all workflow and action YAML files
lint:
	@echo "=== actionlint ==="
	@actionlint

# Lint all shell scripts
# Legacy scripts excluded individually — they'll be deleted in PR 10.
# New scripts (lib/, tools/<name>/, run.sh) must pass shellcheck.
LEGACY_EXCLUDES := \
	-not -path './source/tools/*' \
	-not -path './source/actions/scorecard/format_sarif.sh' \
	-not -path './tools/osv_sbom/*' \
	-not -path './tools/cosign/*' \
	-not -path './tools/check_sbom.sh' \
	-not -path './tools/format_sarif_summary.sh' \
	-not -path './build.sh'

shellcheck:
	@echo "=== shellcheck ==="
	@SCRIPTS=$$(find . -name '*.sh' -not -path './.git/*' $(LEGACY_EXCLUDES)); \
	if [ -n "$$SCRIPTS" ]; then \
		echo $$SCRIPTS | xargs shellcheck; \
	else \
		echo "No non-legacy shell scripts to check yet"; \
	fi

# Run bats tests
bats:
	@echo "=== bats ==="
	@bats test/

# Update a tool version and its checksum
# Usage: make update-tool TOOL=osv VERSION=1.2.3
update-tool:
	@echo "Tool version update helper — not yet implemented (PR 3)"
	@echo "Will download $(TOOL) $(VERSION), compute SHA-256, and patch tools/$(TOOL)/install.sh"
	@exit 1
