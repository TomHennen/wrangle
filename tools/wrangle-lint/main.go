// Command wrangle-lint audits an adopter repo's Dependabot configuration for
// footguns that silently defeat dependency hygiene. It is a config-correctness
// layer, distinct from the security scanners (osv/zizmor/scorecard check the
// adopter's code and workflows; this checks whether the surrounding config is
// wired up). v1 covers .github/dependabot.yml:
//
//	WL001  no effective Dependabot config (file missing, or present with no
//	       `updates` entries) — dependency and action-pin updates never run.
//	WL002  config at .github/dependabot.yaml — Dependabot reads only `.yml`,
//	       so a `.yaml` file is silently ignored.
//	WL003  a github-actions entry globs directory/directories with `**` — it
//	       does not recurse into nested action.yml (and `/**` also provokes
//	       duplicate update PRs).
//	WL004  a composite action.yml directory in the repo is absent from the
//	       github-actions directories — its pins drift from the workflow copies.
//	WL005  an updates entry has no cooldown.default-days >= 7 — bumps land
//	       before the community can surface a supply-chain attack.
//	WL006  workflows pin actions with `uses:` but no github-actions ecosystem
//	       is configured — those action pins never get update PRs.
//
// Findings are suppressible with an inline comment carrying a justification:
//
//	# wrangle-lint: ignore WL00X -- why this is safe here
//
// on the flagged line or the contiguous comment block directly above it. A
// missing file has no line to anchor a comment to and is not suppressible.
//
// Usage: wrangle-lint <src_dir> <out_sarif>
// Exit: 0 SARIF written (with or without findings), 2 tool error (fail closed).
package main

import (
	"bytes"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/owenrumney/go-sarif/v3/pkg/report"
	"github.com/owenrumney/go-sarif/v3/pkg/report/v210/sarif"
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

// level drives both the SARIF result level and (downstream) the markdown
// severity; security-severity orders the GitHub code-scanning view.
var rules = map[string]ruleMeta{
	"WL001": {"error", "7.0", "No effective Dependabot configuration"},
	"WL002": {"error", "6.0", "Dependabot configuration uses an ignored .yaml extension"},
	"WL003": {"error", "7.0", "github-actions directory glob does not recurse into composites"},
	"WL004": {"error", "7.0", "Composite action directory not covered by Dependabot"},
	"WL005": {"warning", "4.0", "Dependabot cooldown missing or shorter than the adoption delay"},
	"WL006": {"error", "7.0", "Workflows pin actions but no github-actions Dependabot ecosystem is configured"},
}

type finding struct {
	ruleID  string
	uri     string // repo-relative path for the SARIF location
	abspath string // file to scan for a suppression directive ("" = none)
	line    int
	message string
}

// A suppression directive naming a specific rule; the trailing text is the
// (required) justification. `\b` after the id rejects a longer typo like WL0044.
var suppressRe = regexp.MustCompile(`wrangle-lint:\s*ignore[\s\[]+(WL\d{3})\b\]?\s*(.*)$`)

// resolve follows a YAML alias to its anchor so `*ref` is treated as its target.
func resolve(n *yaml.Node) *yaml.Node {
	for n != nil && n.Kind == yaml.AliasNode {
		n = n.Alias
	}
	return n
}

func mapGet(n *yaml.Node, key string) *yaml.Node {
	n = resolve(n)
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		if n.Content[i].Value == key {
			return resolve(n.Content[i+1])
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

// externalActionRef matches a pinned reference to an external action or
// reusable workflow (`owner/repo...@ref`) — the kind Dependabot's
// github-actions ecosystem raises update PRs for. Local (`./...`) and
// `docker://` refs are excluded: Dependabot does not bump them.
var externalActionRef = regexp.MustCompile(`^[^./][^@]*/[^@]*@`)

// usesExternalAction reports whether any `uses:` in the node tree pins an
// external action or reusable workflow. It matches a `uses` key at any depth
// (step-level and reusable-workflow job-level), accepting the rare benign
// false positive of a `with:` input literally named `uses`.
func usesExternalAction(n *yaml.Node) bool {
	n = resolve(n)
	if n == nil {
		return false
	}
	if n.Kind == yaml.MappingNode {
		for i := 0; i+1 < len(n.Content); i += 2 {
			v := resolve(n.Content[i+1])
			if n.Content[i].Value == "uses" && v != nil && v.Kind == yaml.ScalarNode {
				val := strings.TrimSpace(v.Value)
				if !strings.HasPrefix(val, "docker://") && externalActionRef.MatchString(val) {
					return true
				}
			}
			if usesExternalAction(v) {
				return true
			}
		}
		return false
	}
	for _, c := range n.Content {
		if usesExternalAction(c) {
			return true
		}
	}
	return false
}

// workflowsPinActions reports whether any .github/workflows file pins an
// external action or reusable workflow — the universal case for needing a
// github-actions Dependabot ecosystem.
func workflowsPinActions(srcDir string) (bool, error) {
	dir := filepath.Join(srcDir, ".github", "workflows")
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || (!strings.HasSuffix(name, ".yml") && !strings.HasSuffix(name, ".yaml")) {
			continue
		}
		content, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return false, err
		}
		// A malformed workflow is the security scanners' concern, not this
		// config audit's — skip it rather than failing the whole lint closed.
		root, err := parseFirstDoc(content, name)
		if err != nil || root == nil {
			continue
		}
		if usesExternalAction(root) {
			return true, nil
		}
	}
	return false, nil
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
			if it = resolve(it); it.Kind == yaml.ScalarNode {
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

func cooldownMessage(eco string) string {
	who := "An"
	if eco != "" {
		who = "The '" + eco + "'"
	}
	return fmt.Sprintf("%s update entry has no cooldown.default-days >= %d, so dependency "+
		"bumps land before the community can surface a supply-chain attack. Add a "+
		"`cooldown:` block with `default-days: %d` to that entry.", who, cooldownMinDays, cooldownMinDays)
}

// parseFirstDoc decodes the first mapping-rooted YAML document, skipping leading
// `---` separators and empty documents (which decode to a null scalar, not an
// empty node). Returns (nil, nil) when no such document exists.
func parseFirstDoc(content []byte, uri string) (*yaml.Node, error) {
	dec := yaml.NewDecoder(bytes.NewReader(content))
	for {
		var doc yaml.Node
		err := dec.Decode(&doc)
		if err == io.EOF {
			return nil, nil
		}
		if err != nil {
			return nil, fmt.Errorf("%s: YAML parse error: %w", uri, err)
		}
		if len(doc.Content) > 0 {
			if r := resolve(doc.Content[0]); r != nil && r.Kind == yaml.MappingNode {
				return r, nil
			}
		}
	}
}

func checkDependabot(ymlPath, uri, srcDir string) ([]finding, error) {
	content, err := os.ReadFile(ymlPath)
	if err != nil {
		return nil, err
	}
	root, err := parseFirstDoc(content, uri)
	if err != nil {
		return nil, err
	}

	var findings []finding
	updates := mapGet(root, "updates")
	if updates == nil || updates.Kind != yaml.SequenceNode || len(updates.Content) == 0 {
		// Present but inert: a comment can still suppress it (the file exists).
		return append(findings, finding{"WL001", uri, ymlPath, 1, fmt.Sprintf(
			"%s has no `updates:` entries, so Dependabot raises no update PRs. Add an "+
				"`updates:` list (see gh_workflow_examples/dependabot.yml).", uri)}), nil
	}

	composites, err := compositeDirs(srcDir)
	if err != nil {
		return nil, err
	}

	hasGitHubActions := false
	for _, entry := range updates.Content {
		entry = resolve(entry)
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
			findings = append(findings, finding{"WL005", uri, ymlPath, anchorLine, cooldownMessage(eco)})
		}

		if eco != "github-actions" {
			continue
		}
		hasGitHubActions = true

		dirs := entryDirectories(entry)
		hasGlob := false
		for _, d := range dirs {
			// Any glob makes literal WL004 coverage comparison meaningless — a
			// `/actions/*` is a valid covering config, so comparing its literal
			// text against real dirs would spuriously flag every composite it
			// covers. `**` is additionally flagged by WL003 below.
			if strings.Contains(d.val, "*") {
				hasGlob = true
			}
			if strings.Contains(d.val, "**") {
				findings = append(findings, finding{"WL003", uri, ymlPath, d.line, fmt.Sprintf(
					"The github-actions entry's '%s' is a `**` glob: Dependabot does not recurse "+
						"into nested action.yml (so composite actions are never bumped) and `/**` "+
						"also creates duplicate PRs. List each directory explicitly, e.g. "+
						"`directories: [\"/\", \"/path/to/your/action\"]`.", d.val)})
			}
		}
		// A glob directory can't be coverage-checked literally; skip WL004 when
		// any glob is present (a `**` is already flagged by WL003).
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
			findings = append(findings, finding{"WL004", uri, ymlPath, anchor, fmt.Sprintf(
				"Composite action '%s/action.yml' is not covered by the github-actions entry, so "+
					"its pinned actions never get update PRs. Add \"%s\" to that entry's `directories`.",
				c, c)})
		}
	}

	if !hasGitHubActions {
		pin, err := workflowsPinActions(srcDir)
		if err != nil {
			return nil, err
		}
		if pin {
			// updates.Line is the first entry's line (a sequence node), which is
			// the anchor a suppression comment must sit directly above.
			findings = append(findings, finding{"WL006", uri, ymlPath, updates.Line,
				"Workflows under .github/workflows pin actions with `uses:`, but the Dependabot " +
					"config has no `github-actions` ecosystem entry, so those action pins never get " +
					"update PRs. Add an `updates:` entry with `package-ecosystem: \"github-actions\"` " +
					"(see gh_workflow_examples/dependabot.yml)."})
		}
	}
	return findings, nil
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
				"ignored, so no update PRs run. Rename it: `git mv .github/dependabot.yaml " +
				".github/dependabot.yml`."}}, nil
	default:
		return []finding{{"WL001", ".github/dependabot.yml", "", 1,
			"No .github/dependabot.yml, so no dependency or action-pin update PRs run. Copy " +
				"gh_workflow_examples/dependabot.yml to .github/dependabot.yml and enable the " +
				"ecosystems you use."}}, nil
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

// writeSARIF emits SARIF 2.1.0 via go-sarif, with one rule entry per rule that
// fired and a result per finding.
func writeSARIF(findings []finding, outPath string) error {
	rep := report.NewV210Report()
	run := sarif.NewRunWithInformationURI("wrangle-lint", "https://github.com/TomHennen/wrangle")

	usedSet := map[string]bool{}
	for _, f := range findings {
		usedSet[f.ruleID] = true
	}
	var used []string
	for id := range usedSet {
		used = append(used, id)
	}
	sort.Strings(used)
	for _, id := range used {
		m := rules[id]
		pb := sarif.NewPropertyBag()
		pb.Add("security-severity", m.severity)
		run.AddRule(id).
			WithShortDescription(sarif.NewMultiformatMessageString().WithText(m.desc)).
			WithDefaultConfiguration(sarif.NewReportingConfiguration().WithLevel(m.level)).
			WithProperties(pb)
	}
	for _, f := range findings {
		run.CreateResultForRule(f.ruleID).
			WithLevel(rules[f.ruleID].level).
			WithMessage(sarif.NewTextMessage(f.message)).
			AddLocation(sarif.NewLocationWithPhysicalLocation(
				sarif.NewPhysicalLocation().
					WithArtifactLocation(sarif.NewSimpleArtifactLocation(f.uri)).
					WithRegion(sarif.NewRegion().WithStartLine(f.line)),
			))
	}
	rep.AddRun(run)
	return rep.WriteFile(outPath)
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
	if err := writeSARIF(findings, args[2]); err != nil {
		fmt.Fprintf(os.Stderr, "wrangle-lint: %v\nwrangle-lint: failing closed.\n", err)
		return 2
	}
	return 0
}

func main() {
	os.Exit(run(os.Args))
}
