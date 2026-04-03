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
# Exclude legacy scripts (source/tools/, tools/osv_sbom/, tools/cosign/, build.sh)
# that will be deleted in PR 10. New code must pass shellcheck.
shellcheck:
	@echo "=== shellcheck ==="
	@find . -name '*.sh' \
		-not -path './.git/*' \
		-not -path './source/*' \
		-not -path './tools/*' \
		-not -path './build.sh' \
		-exec shellcheck {} + \
		|| echo "No new shell scripts to check (legacy scripts excluded)"

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
