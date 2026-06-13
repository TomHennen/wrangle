// Command wrangle-lint audits an adopter repo's wrangle-relevant configuration
// for footguns that silently defeat the protection wrangle sets up. It is a
// config-correctness layer, distinct from the security scanning osv/zizmor/
// scorecard do: those check the adopter's code and workflows; this checks
// whether the surrounding configuration is wired up to deliver what wrangle
// promises.
//
// v1 covers Dependabot configuration correctness — the class behind the
// "/**"-doesn't-recurse coverage gap:
//
//	WL001  no .github/dependabot.yml — dependency/action-pin updates never run.
//	WL002  config at .github/dependabot.yaml — Dependabot reads only .yml, so a
//	       .yaml file is silently ignored.
//	WL003  a github-actions entry globs directory/directories with ** — it does
//	       not recurse into nested action.yml (and /** provokes duplicate PRs).
//	WL004  a composite action.yml directory in the repo is absent from the
//	       github-actions directories — its pins drift from the workflow copies.
//	WL005  an updates entry has no cooldown.default-days >= 7 — bumps land
//	       before the community can surface a supply-chain attack.
//
// Findings are suppressible with an inline comment carrying a justification:
//
//	# wrangle-lint: ignore WL00X -- why this is safe here
//
// on the flagged line or in the contiguous comment block directly above it.
// The justification is required. WL001 (missing file) has no line to anchor a
// comment to and is not suppressible.
//
// Usage: wrangle-lint <src_dir> <out_sarif>
// Exit: 0 SARIF written (with or without findings), 2 tool error (fail closed).
package main

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

const cooldownMinDays = 7

// Directories that may hold action.yml but are not the adopter's to bump
// (vendored or tooling state), so a missing Dependabot entry for them is noise.
var skipDirs = map[string]bool{
	".git": true, "node_modules": true, "vendor": true, ".beads": true, ".claude": true,
}

type ruleMeta struct {
	level, severity, desc string
}

// level drives both the SARIF result level and the markdown severity
// (error=HIGH, warning=MED).
var rules = map[string]ruleMeta{
	"WL001": {"warning", "5.0", "No Dependabot configuration"},
	"WL002": {"error", "6.0", "Dependabot configuration uses an ignored .yaml extension"},
	"WL003": {"error", "7.0", "github-actions directory glob does not recurse into composites"},
	"WL004": {"error", "7.0", "Composite action directory not covered by Dependabot"},
	"WL005": {"warning", "4.0", "Dependabot cooldown missing or shorter than the adoption delay"},
}

type finding struct {
	ruleID  string
	uri     string // repo-relative path for the SARIF location
	abspath string // file to scan for a suppression directive ("" = none)
	line    int
	message string
}

// A suppression directive naming a specific rule; the trailing text is the
// (required) justification.
var suppressRe = regexp.MustCompile(`wrangle-lint:\s*ignore[\s\[]+(WL\d{3})\]?\s*(.*)$`)

func mapGet(n *yaml.Node, key string) *yaml.Node {
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		if n.Content[i].Value == key {
			return n.Content[i+1]
		}
	}
	return nil
}

// normDir normalizes a Dependabot directory to leading-slash, no-trailing-slash.
func normDir(s string) string {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, "/") {
		s = "/" + s
	}
	if len(s) > 1 {
		s = strings.TrimRight(s, "/")
	}
	return s
}

// compositeDirs returns repo-relative dirs (leading-slash form) holding a
// composite action.yml.
func compositeDirs(srcDir string) (map[string]bool, error) {
	found := map[string]bool{}
	err := filepath.WalkDir(srcDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && skipDirs[d.Name()] {
			return filepath.SkipDir
		}
		if !d.IsDir() && (d.Name() == "action.yml" || d.Name() == "action.yaml") {
			rel, rerr := filepath.Rel(srcDir, filepath.Dir(path))
			if rerr != nil {
				return rerr
			}
			if rel == "." {
				found["/"] = true
			} else {
				found["/"+filepath.ToSlash(rel)] = true
			}
		}
		return nil
	})
	return found, err
}

type dirRef struct {
	val  string
	line int
}

func entryDirectories(entry *yaml.Node) []dirRef {
	var out []dirRef
	if s := mapGet(entry, "directory"); s != nil && s.Kind == yaml.ScalarNode {
		out = append(out, dirRef{s.Value, s.Line})
	}
	if p := mapGet(entry, "directories"); p != nil && p.Kind == yaml.SequenceNode {
		for _, it := range p.Content {
			if it.Kind == yaml.ScalarNode {
				out = append(out, dirRef{it.Value, it.Line})
			}
		}
	}
	return out
}

// cooldownDays returns default-days and whether it was present and parseable.
func cooldownDays(entry *yaml.Node) (int, bool) {
	cooldown := mapGet(entry, "cooldown")
	if cooldown == nil || cooldown.Kind != yaml.MappingNode {
		return 0, false
	}
	dd := mapGet(cooldown, "default-days")
	if dd == nil || dd.Kind != yaml.ScalarNode {
		return 0, false
	}
	n, err := strconv.Atoi(strings.TrimSpace(dd.Value))
	if err != nil {
		return 0, false
	}
	return n, true
}

func checkDependabot(ymlPath, uri, srcDir string) ([]finding, error) {
	content, err := os.ReadFile(ymlPath)
	if err != nil {
		return nil, err
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(content, &doc); err != nil {
		return nil, fmt.Errorf("%s: YAML parse error: %w", uri, err)
	}
	if len(doc.Content) == 0 {
		return nil, nil
	}
	root := doc.Content[0]
	composites, err := compositeDirs(srcDir)
	if err != nil {
		return nil, err
	}

	var fs []finding
	updates := mapGet(root, "updates")
	if updates == nil || updates.Kind != yaml.SequenceNode {
		return fs, nil
	}
	for _, entry := range updates.Content {
		if entry.Kind != yaml.MappingNode {
			continue
		}
		eco := ""
		anchorLine := entry.Line
		if ecoNode := mapGet(entry, "package-ecosystem"); ecoNode != nil {
			eco = ecoNode.Value
			anchorLine = ecoNode.Line
		}

		if days, ok := cooldownDays(entry); !ok || days < cooldownMinDays {
			fs = append(fs, finding{"WL005", uri, ymlPath, anchorLine, fmt.Sprintf(
				"The '%s' update entry has no cooldown.default-days >= %d. Without it, "+
					"dependency bumps land immediately, before the community can surface a "+
					"supply-chain attack. Add cooldown.default-days: %d.",
				eco, cooldownMinDays, cooldownMinDays)})
		}

		if eco != "github-actions" {
			continue
		}

		dirs := entryDirectories(entry)
		hasGlob := false
		for _, d := range dirs {
			if strings.Contains(d.val, "**") {
				hasGlob = true
				fs = append(fs, finding{"WL003", uri, ymlPath, d.line, fmt.Sprintf(
					"The github-actions entry uses a '%s' glob. github-actions does not "+
						"recurse into nested action.yml, so composite actions are never bumped "+
						"(and '/**' provokes duplicate update PRs). List each directory holding "+
						"an action.yml explicitly.", d.val)})
			}
		}
		// A glob is already flagged (WL003); enumerating coverage on top would
		// double-report. Only check coverage when explicit directories are used.
		if hasGlob {
			continue
		}
		listed := map[string]bool{}
		for _, d := range dirs {
			listed[normDir(d.val)] = true
		}
		anchor := anchorLine
		if len(dirs) > 0 {
			anchor = dirs[len(dirs)-1].line
		}
		var missing []string
		for c := range composites {
			if !listed[c] {
				missing = append(missing, c)
			}
		}
		sort.Strings(missing)
		for _, c := range missing {
			fs = append(fs, finding{"WL004", uri, ymlPath, anchor, fmt.Sprintf(
				"Composite action '%s/action.yml' is not listed in the github-actions "+
					"directories. Its third-party pins will drift from the workflow copies. "+
					"Add a directory entry for it.", c)})
		}
	}
	return fs, nil
}

func runChecks(srcDir string) ([]finding, error) {
	ymlPath := filepath.Join(srcDir, ".github", "dependabot.yml")
	yamlPath := filepath.Join(srcDir, ".github", "dependabot.yaml")
	switch {
	case fileExists(ymlPath):
		return checkDependabot(ymlPath, ".github/dependabot.yml", srcDir)
	case fileExists(yamlPath):
		return []finding{{"WL002", ".github/dependabot.yaml", yamlPath, 1,
			"Dependabot reads only .github/dependabot.yml; this .yaml file is silently " +
				"ignored, so no update PRs run. Rename it to dependabot.yml."}}, nil
	default:
		return []finding{{"WL001", ".github/dependabot.yml", "", 1,
			"No .github/dependabot.yml found. Dependency and action-pin updates " +
				"(including your wrangle pin) never run. Copy " +
				"gh_workflow_examples/dependabot.yml to .github/dependabot.yml."}}, nil
	}
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

func isSuppressed(lines []string, line int, ruleID string) bool {
	if line < 1 || line > len(lines) {
		return false
	}
	justified := func(s string) bool {
		m := suppressRe.FindStringSubmatch(s)
		if m == nil || m[1] != ruleID {
			return false
		}
		return strings.TrimSpace(strings.TrimLeft(m[2], " \t:-")) != ""
	}
	if justified(lines[line-1]) {
		return true
	}
	for i := line - 2; i >= 0; i-- {
		if !strings.HasPrefix(strings.TrimLeft(lines[i], " \t"), "#") {
			break
		}
		if justified(lines[i]) {
			return true
		}
	}
	return false
}

func filterSuppressed(findings []finding) ([]finding, error) {
	cache := map[string][]string{}
	var kept []finding
	for _, f := range findings {
		if f.abspath == "" {
			kept = append(kept, f)
			continue
		}
		lines, ok := cache[f.abspath]
		if !ok {
			b, err := os.ReadFile(f.abspath)
			if err != nil {
				return nil, err
			}
			lines = strings.Split(string(b), "\n")
			cache[f.abspath] = lines
		}
		if !isSuppressed(lines, f.line, f.ruleID) {
			kept = append(kept, f)
		}
	}
	return kept, nil
}

func buildSARIF(findings []finding) sarifLog {
	usedSet := map[string]bool{}
	for _, f := range findings {
		usedSet[f.ruleID] = true
	}
	var used []string
	for id := range usedSet {
		used = append(used, id)
	}
	sort.Strings(used)

	driverRules := make([]sarifRule, 0, len(used))
	for _, id := range used {
		m := rules[id]
		driverRules = append(driverRules, sarifRule{
			ID:                   id,
			Name:                 id,
			ShortDescription:     sarifText{m.desc},
			DefaultConfiguration: sarifRuleCfg{m.level},
			Properties:           sarifRuleProps{m.severity},
		})
	}
	results := make([]sarifResult, 0, len(findings))
	for _, f := range findings {
		results = append(results, sarifResult{
			RuleID:  f.ruleID,
			Level:   rules[f.ruleID].level,
			Message: sarifText{f.message},
			Locations: []sarifLocation{{PhysicalLocation: sarifPhysical{
				ArtifactLocation: sarifArtifact{f.uri},
				Region:           sarifRegion{f.line},
			}}},
		})
	}
	return sarifLog{
		Version: "2.1.0",
		Schema:  "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
		Runs: []sarifRun{{
			Tool: sarifTool{Driver: sarifDriver{
				Name:           "wrangle-lint",
				InformationURI: "https://github.com/TomHennen/wrangle",
				Rules:          driverRules,
			}},
			Results: results,
		}},
	}
}

func run(args []string) int {
	if len(args) != 3 {
		fmt.Fprintln(os.Stderr, "Usage: wrangle-lint <src_dir> <out_sarif>")
		return 2
	}
	findings, err := runChecks(args[1])
	if err == nil {
		findings, err = filterSuppressed(findings)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "wrangle-lint: %v\nwrangle-lint: failing closed.\n", err)
		return 2
	}
	sort.SliceStable(findings, func(i, j int) bool {
		if findings[i].uri != findings[j].uri {
			return findings[i].uri < findings[j].uri
		}
		if findings[i].line != findings[j].line {
			return findings[i].line < findings[j].line
		}
		return findings[i].ruleID < findings[j].ruleID
	})
	data, err := json.MarshalIndent(buildSARIF(findings), "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "wrangle-lint: %v\nwrangle-lint: failing closed.\n", err)
		return 2
	}
	if err := os.WriteFile(args[2], append(data, '\n'), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "wrangle-lint: %v\nwrangle-lint: failing closed.\n", err)
		return 2
	}
	return 0
}

func main() {
	os.Exit(run(os.Args))
}
