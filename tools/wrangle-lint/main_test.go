package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// writeRepo materializes files (path -> content, relative to the repo root)
// in a temp dir and returns the root.
func writeRepo(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for rel, content := range files {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// ruleIDs runs the full pipeline (checks + suppression) and returns the sorted
// rule ids that fired.
func ruleIDs(t *testing.T, root string) []string {
	t.Helper()
	findings, err := runChecks(root)
	if err != nil {
		t.Fatalf("runChecks: %v", err)
	}
	findings, err = filterSuppressed(findings)
	if err != nil {
		t.Fatalf("filterSuppressed: %v", err)
	}
	var ids []string
	for _, f := range findings {
		ids = append(ids, f.ruleID)
	}
	sort.Strings(ids)
	return ids
}

func has(ids []string, want string) bool {
	for _, id := range ids {
		if id == want {
			return true
		}
	}
	return false
}

const cleanConfig = `version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    cooldown:
      default-days: 7
`

func TestRules(t *testing.T) {
	cases := []struct {
		name    string
		files   map[string]string
		want    string // rule expected to fire ("" => none)
		notWant string // rule expected NOT to fire
	}{
		{
			name:    "clean config has no findings",
			files:   map[string]string{".github/dependabot.yml": cleanConfig},
			notWant: "WL005",
		},
		{
			name:  "WL001 missing config",
			files: map[string]string{"README.md": "x"},
			want:  "WL001",
		},
		{
			name:  "WL002 wrong extension",
			files: map[string]string{".github/dependabot.yaml": cleanConfig},
			want:  "WL002",
		},
		{
			name: "WL003 globbed github-actions directory",
			files: map[string]string{".github/dependabot.yml": `version: 2
updates:
  - package-ecosystem: "github-actions"
    directories:
      - "/**"
    cooldown:
      default-days: 7
`},
			want: "WL003",
		},
		{
			name: "WL004 composite dir not listed",
			files: map[string]string{
				".github/dependabot.yml": cleanConfig,
				"myaction/action.yml":    "name: x\nruns:\n  using: composite\n  steps: []\n",
			},
			want: "WL004",
		},
		{
			name: "WL004 not fired when composite dir is listed",
			files: map[string]string{
				".github/dependabot.yml": `version: 2
updates:
  - package-ecosystem: "github-actions"
    directories:
      - "/"
      - "/myaction"
    cooldown:
      default-days: 7
`,
				"myaction/action.yml": "name: x\nruns:\n  using: composite\n  steps: []\n",
			},
			notWant: "WL004",
		},
		{
			name: "WL005 missing cooldown",
			files: map[string]string{".github/dependabot.yml": `version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
`},
			want: "WL005",
		},
		{
			name: "WL005 cooldown shorter than the adoption delay",
			files: map[string]string{".github/dependabot.yml": `version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    cooldown:
      default-days: 2
`},
			want: "WL005",
		},
		{
			name: "WL004 ignores vendored composites",
			files: map[string]string{
				".github/dependabot.yml":      cleanConfig,
				"node_modules/dep/action.yml": "name: x\n",
			},
			notWant: "WL004",
		},
		{
			name:  "WL001 fires when the file has no updates entries",
			files: map[string]string{".github/dependabot.yml": "version: 2\n"},
			want:  "WL001",
		},
		{
			name: "WL005 not fired for an aliased cooldown (alias resolution)",
			files: map[string]string{".github/dependabot.yml": `version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    cooldown: &cd
      default-days: 7
  - package-ecosystem: "gomod"
    directory: "/"
    cooldown: *cd
`},
			notWant: "WL005",
		},
		{
			name:  "multi-document: a leading --- empty doc is skipped, not no-op'd",
			files: map[string]string{".github/dependabot.yml": "---\n---\nversion: 2\nupdates:\n  - package-ecosystem: \"github-actions\"\n    directory: \"/\"\n"},
			want:  "WL005",
		},
		{
			name: "WL006 workflows pin actions but no github-actions ecosystem",
			files: map[string]string{
				".github/dependabot.yml": `version: 2
updates:
  - package-ecosystem: "gomod"
    directory: "/"
    cooldown:
      default-days: 7
`,
				".github/workflows/ci.yml": "on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n",
			},
			want: "WL006",
		},
		{
			name: "WL006 not fired when github-actions ecosystem is present",
			files: map[string]string{
				".github/dependabot.yml":   cleanConfig,
				".github/workflows/ci.yml": "on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n",
			},
			notWant: "WL006",
		},
		{
			name: "WL006 not fired when no workflow pins an external action",
			files: map[string]string{
				".github/dependabot.yml": `version: 2
updates:
  - package-ecosystem: "gomod"
    directory: "/"
    cooldown:
      default-days: 7
`,
				".github/workflows/ci.yml": "on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: ./.github/actions/local\n",
			},
			notWant: "WL006",
		},
		{
			name: "WL006 not fired with no workflows at all",
			files: map[string]string{".github/dependabot.yml": `version: 2
updates:
  - package-ecosystem: "gomod"
    directory: "/"
    cooldown:
      default-days: 7
`},
			notWant: "WL006",
		},
		{
			name: "WL006 detects reusable workflow pins",
			files: map[string]string{
				".github/dependabot.yml": `version: 2
updates:
  - package-ecosystem: "gomod"
    directory: "/"
    cooldown:
      default-days: 7
`,
				".github/workflows/release.yml": "on: push\njobs:\n  b:\n    uses: TomHennen/wrangle/.github/workflows/build_go.yml@abc123\n",
			},
			want: "WL006",
		},
		{
			name: "WL006 suppressible with a justified ignore",
			files: map[string]string{
				".github/dependabot.yml": `version: 2
updates:
  # wrangle-lint: ignore WL006 -- action pins managed in a central repo
  - package-ecosystem: "gomod"
    directory: "/"
    cooldown:
      default-days: 7
`,
				".github/workflows/ci.yml": "on: push\njobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n",
			},
			notWant: "WL006",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ids := ruleIDs(t, writeRepo(t, tc.files))
			if tc.want != "" && !has(ids, tc.want) {
				t.Errorf("expected %s to fire, got %v", tc.want, ids)
			}
			if tc.notWant != "" && has(ids, tc.notWant) {
				t.Errorf("expected %s NOT to fire, got %v", tc.notWant, ids)
			}
		})
	}
}

func TestSuppression(t *testing.T) {
	cases := []struct {
		name       string
		dependabot string
		suppressed bool
	}{
		{
			name: "justified ignore above the line suppresses",
			dependabot: `version: 2
updates:
  - package-ecosystem: "github-actions"
    directories:
      # wrangle-lint: ignore WL003 -- monorepo, no composite actions
      - "/**"
    cooldown:
      default-days: 7
`,
			suppressed: true,
		},
		{
			name: "ignore without justification does not suppress",
			dependabot: `version: 2
updates:
  - package-ecosystem: "github-actions"
    directories:
      # wrangle-lint: ignore WL003
      - "/**"
    cooldown:
      default-days: 7
`,
			suppressed: false,
		},
		{
			name: "ignore for a different rule does not suppress",
			dependabot: `version: 2
updates:
  - package-ecosystem: "github-actions"
    directories:
      # wrangle-lint: ignore WL005 -- wrong rule
      - "/**"
    cooldown:
      default-days: 7
`,
			suppressed: false,
		},
		{
			name: "a typo'd four-digit id does not suppress (WL0033 != WL003)",
			dependabot: `version: 2
updates:
  - package-ecosystem: "github-actions"
    directories:
      # wrangle-lint: ignore WL0033 -- typo, four digits
      - "/**"
    cooldown:
      default-days: 7
`,
			suppressed: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ids := ruleIDs(t, writeRepo(t, map[string]string{".github/dependabot.yml": tc.dependabot}))
			fired := has(ids, "WL003")
			if tc.suppressed && fired {
				t.Errorf("expected WL003 suppressed, got %v", ids)
			}
			if !tc.suppressed && !fired {
				t.Errorf("expected WL003 to fire, got %v", ids)
			}
		})
	}
}

func TestMalformedFailsClosed(t *testing.T) {
	root := writeRepo(t, map[string]string{".github/dependabot.yml": "updates:\n  - bad: [unclosed\n"})
	if _, err := runChecks(root); err == nil {
		t.Fatal("expected a tool error on malformed YAML, got nil")
	}
}

type sarifResult struct {
	RuleID    string `json:"ruleId"`
	Locations []struct {
		PhysicalLocation struct {
			ArtifactLocation struct {
				URI string `json:"uri"`
			} `json:"artifactLocation"`
			Region struct {
				StartLine int `json:"startLine"`
			} `json:"region"`
		} `json:"physicalLocation"`
	} `json:"locations"`
}

// parseSARIF reads a SARIF file the binary wrote, asserts it is valid and names
// the wrangle-lint driver, and returns its results.
func parseSARIF(t *testing.T, path string) []sarifResult {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var log struct {
		Runs []struct {
			Tool struct {
				Driver struct{ Name string } `json:"driver"`
			} `json:"tool"`
			Results []sarifResult `json:"results"`
		} `json:"runs"`
	}
	if err := json.Unmarshal(b, &log); err != nil {
		t.Fatalf("invalid SARIF: %v", err)
	}
	if len(log.Runs) != 1 || log.Runs[0].Tool.Driver.Name != "wrangle-lint" {
		t.Fatalf("unexpected SARIF shape: %s", b)
	}
	return log.Runs[0].Results
}

func resultRuleIDs(results []sarifResult) []string {
	var ids []string
	for _, r := range results {
		ids = append(ids, r.RuleID)
	}
	return ids
}

// TestRunEndToEnd drives run() (arg parsing → SARIF file → exit code), the path
// the adapter invokes, without an external binary. It also pins that go-sarif
// carries the file+line location through, since the adapter wrapper relies on it.
func TestRunEndToEnd(t *testing.T) {
	dir := t.TempDir()

	clean := writeRepo(t, map[string]string{".github/dependabot.yml": cleanConfig})
	cleanOut := filepath.Join(dir, "clean.sarif")
	if code := run([]string{"wrangle-lint", clean, cleanOut}); code != 0 {
		t.Fatalf("clean repo: exit %d, want 0", code)
	}
	if results := parseSARIF(t, cleanOut); len(results) != 0 {
		t.Errorf("clean repo: want no results, got %v", resultRuleIDs(results))
	}

	glob := writeRepo(t, map[string]string{".github/dependabot.yml": `version: 2
updates:
  - package-ecosystem: "github-actions"
    directories:
      - "/**"
    cooldown:
      default-days: 7
`})
	globOut := filepath.Join(dir, "glob.sarif")
	// Findings keep exit 0 (the adapter derives 1 from a non-empty result set);
	// only a tool error is non-zero.
	if code := run([]string{"wrangle-lint", glob, globOut}); code != 0 {
		t.Fatalf("glob repo: exit %d, want 0", code)
	}
	results := parseSARIF(t, globOut)
	if !has(resultRuleIDs(results), "WL003") {
		t.Fatalf("glob repo: want WL003, got %v", resultRuleIDs(results))
	}
	loc := results[0].Locations
	if len(loc) == 0 || loc[0].PhysicalLocation.ArtifactLocation.URI != ".github/dependabot.yml" {
		t.Errorf("WL003 location uri not carried through: %+v", results[0])
	}
	if len(loc) > 0 && loc[0].PhysicalLocation.Region.StartLine < 1 {
		t.Errorf("WL003 startLine = %d, want >= 1", loc[0].PhysicalLocation.Region.StartLine)
	}

	bad := writeRepo(t, map[string]string{".github/dependabot.yml": "updates:\n  - bad: [unclosed\n"})
	if code := run([]string{"wrangle-lint", bad, filepath.Join(dir, "bad.sarif")}); code != 2 {
		t.Errorf("malformed: exit %d, want 2", code)
	}
	if code := run([]string{"wrangle-lint", clean}); code != 2 {
		t.Errorf("bad args: exit %d, want 2", code)
	}
}

// TestDogfood asserts the wrangle repo's own config passes clean — wrangle uses
// its own tooling, so a finding here is a real bug, not a test fixture.
func TestDogfood(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(repoRoot, ".github", "dependabot.yml")); err != nil {
		t.Skipf("repo root not found at %s: %v", repoRoot, err)
	}
	ids := ruleIDs(t, repoRoot)
	if len(ids) != 0 {
		t.Errorf("wrangle's own config produced findings: %v", ids)
	}
}
