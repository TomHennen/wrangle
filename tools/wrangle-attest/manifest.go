package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Predicate types the engine knows how to build. A manifest naming any other
// type fails closed — an unrecognized type would otherwise pass an unvalidated
// blob through as a signed attestation.
const (
	predicateSPDX      = "https://spdx.dev/Document"
	predicateOSV       = "https://ossf.github.io/osv-schema/results"
	predicateScorecard = "https://scorecard.dev/result/v0.1"
	predicateScanV1    = "https://github.com/TomHennen/wrangle/attestation/scan/v1"
)

// scanTools is the allowlist of honored <root>/scan/<tool>/ subdirectories. A
// build-time dependency could plant scan/<faketool>/wrangle_attestation_metadata.json
// at a canonical-shaped path; only the tools wrangle actually runs are signed.
var scanTools = map[string]bool{
	"osv":               true,
	"zizmor":            true,
	"wrangle-lint":      true,
	"scorecard":         true,
	"dependency-review": true,
}

// manifest is the tool↔engine contract written next to each native result.
// `result-file` is resolved relative to the manifest's own directory so a
// producer cannot escape its metadata dir or reach an absolute path.
type manifest struct {
	PredicateType string `json:"predicate-type"`
	ResultFile    string `json:"result-file"`
	Tool          *struct {
		Name    string `json:"name"`
		Version string `json:"version"`
	} `json:"tool"`
	Result string `json:"result"`

	// dir is the manifest's own directory; set on discovery, not from JSON.
	dir string
}

// validate enforces the pinned manifest schema, treating the manifest as
// untrusted scan output. tool/result are required ONLY for the scan/v1 thin
// envelope and ignored for passthrough predicates.
func (m *manifest) validate() error {
	if m.PredicateType == "" {
		return errors.New("missing predicate-type")
	}
	if m.ResultFile == "" {
		return errors.New("missing result-file")
	}
	// A result-file is a name within the manifest's dir, never an escape.
	if !filepath.IsLocal(m.ResultFile) {
		return fmt.Errorf("result-file %q must be a path within the manifest directory", m.ResultFile)
	}
	switch m.PredicateType {
	case predicateSPDX, predicateOSV, predicateScorecard:
		// Passthrough: the result file IS the predicate; no extra fields.
	case predicateScanV1:
		if m.Tool == nil || m.Tool.Name == "" {
			return fmt.Errorf("%s requires tool.name", predicateScanV1)
		}
		if m.Result != "clean" && m.Result != "findings" {
			return fmt.Errorf("%s requires result clean|findings, got %q", predicateScanV1, m.Result)
		}
	default:
		return fmt.Errorf("unknown predicate-type %q", m.PredicateType)
	}
	return nil
}

// resultPath is the absolute path to the manifest's native result file, with
// symlinks resolved and asserted to stay within the manifest's own directory.
// filepath.IsLocal in validate blocks lexical `..`/absolute paths but follows
// symlinks; a result-file symlinked out of its dir would otherwise read a
// sibling artifact or an arbitrary file into a wrangle-signed predicate.
func (m *manifest) resultPath() (string, error) {
	realDir, err := filepath.EvalSymlinks(m.dir)
	if err != nil {
		return "", fmt.Errorf("result-file dir: %w", err)
	}
	realPath, err := filepath.EvalSymlinks(filepath.Join(m.dir, m.ResultFile))
	if err != nil {
		return "", fmt.Errorf("result-file: %w", err)
	}
	rel, err := filepath.Rel(realDir, realPath)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("result-file %q resolves outside the manifest directory", m.ResultFile)
	}
	return realPath, nil
}

const manifestFile = "wrangle_attestation_metadata.json"

// discoverManifests honors two fixed locations per root: the canonical top-level
// <root>/wrangle_attestation_metadata.json and, one level down, each
// <root>/scan/<tool>/wrangle_attestation_metadata.json (a bounded readdir of the
// immediate children of <root>/scan/, no recursion). Any other such file in the
// tree — deeper, or outside those locations — is ignored, not signed, since a
// build-time dependency could plant one to forge a wrangle-signed attestation.
// Results are sorted by dir for deterministic output. A missing manifest is not
// an error — a build may legitimately produce none; a malformed manifest at an
// honored location fails the whole run (fail closed).
func discoverManifests(roots []string) ([]manifest, error) {
	var found []manifest
	for _, root := range roots {
		info, err := os.Stat(root)
		if err != nil {
			return nil, fmt.Errorf("metadata-root %q: %w", root, err)
		}
		if !info.IsDir() {
			return nil, fmt.Errorf("metadata-root %q is not a directory", root)
		}
		dirs := []string{root}
		scanDirs, err := scanToolDirs(root)
		if err != nil {
			return nil, err
		}
		dirs = append(dirs, scanDirs...)
		for _, dir := range dirs {
			m, ok, err := manifestAt(dir)
			if err != nil {
				return nil, err
			}
			if ok {
				found = append(found, m)
			}
		}
	}
	sort.Slice(found, func(i, j int) bool { return found[i].dir < found[j].dir })
	seen := make(map[string]bool, len(found))
	for _, m := range found {
		if seen[m.dir] {
			return nil, fmt.Errorf("duplicate manifest directory %q", m.dir)
		}
		seen[m.dir] = true
	}
	return found, nil
}

// scanToolDirs returns the honored child directories of <root>/scan/: only the
// allowlisted tool names (scanTools), never a bare scan/* glob. A missing scan/
// dir is not an error. Non-directory entries and unknown names are skipped; the
// lookup never recurses below scan/<tool>/.
func scanToolDirs(root string) ([]string, error) {
	scanRoot := filepath.Join(root, "scan")
	entries, err := os.ReadDir(scanRoot)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("%s: %w", scanRoot, err)
	}
	var dirs []string
	for _, e := range entries {
		if e.IsDir() && scanTools[e.Name()] {
			dirs = append(dirs, filepath.Join(scanRoot, e.Name()))
		}
	}
	return dirs, nil
}

// manifestAt parses the canonical manifest in dir, if present. A missing file
// reports ok=false with no error; a present-but-malformed one fails closed.
func manifestAt(dir string) (manifest, bool, error) {
	path := filepath.Join(dir, manifestFile)
	if _, err := os.Stat(path); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return manifest{}, false, nil
		}
		return manifest{}, false, fmt.Errorf("%s: %w", path, err)
	}
	m, err := parseManifest(path)
	if err != nil {
		return manifest{}, false, fmt.Errorf("%s: %w", path, err)
	}
	return m, true, nil
}

func parseManifest(path string) (manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return manifest{}, err
	}
	var m manifest
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&m); err != nil {
		return manifest{}, fmt.Errorf("invalid manifest JSON: %w", err)
	}
	m.dir = filepath.Dir(path)
	if err := m.validate(); err != nil {
		return manifest{}, err
	}
	return m, nil
}
