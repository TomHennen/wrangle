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
	if filepath.IsAbs(m.ResultFile) || containsDotDot(m.ResultFile) {
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

func containsDotDot(p string) bool {
	for _, seg := range strings.Split(filepath.ToSlash(p), "/") {
		if seg == ".." {
			return true
		}
	}
	return false
}

// resultPath is the absolute path to the manifest's native result file.
func (m *manifest) resultPath() string {
	return filepath.Join(m.dir, m.ResultFile)
}

// discoverManifests walks each root for manifest.json files, parses and
// validates each, and returns them sorted by path for deterministic output.
// Any malformed manifest fails the whole run (fail closed). A root with no
// manifests is not an error — a build may legitimately produce none.
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
		err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() || d.Name() != "manifest.json" {
				return nil
			}
			m, err := parseManifest(path)
			if err != nil {
				return fmt.Errorf("%s: %w", path, err)
			}
			found = append(found, m)
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Slice(found, func(i, j int) bool { return found[i].dir < found[j].dir })
	return found, nil
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
