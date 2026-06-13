package main

import (
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
