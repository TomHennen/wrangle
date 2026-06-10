# Fixture: every pointer resolves

- **Exit codes are honored.**
  → enforced by: `tools/demo/test.bats::demo: does the thing`,
  `tools/demo/test.bats::demo: handles colons: like real wrangle test names do (exit 0)`
- **No curl piped to sh.** → enforced by: `WSL777`
- **Helper exists.** → enforced by: `lib/helper.sh`
- A line with backticks but no marker: `lib/nonexistent.sh` and `$WRANGLE_BIN_DIR` are ignored.
- **Marker with a non-path code span too.** → enforced by: `lib/helper.sh` (sets `$WRANGLE_BIN_DIR`)
