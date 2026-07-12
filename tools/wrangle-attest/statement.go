package main

import (
	"encoding/json"
	"fmt"
	"os"

	intoto "github.com/in-toto/attestation/go/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/types/known/structpb"
)

// buildStatement turns one manifest into an unsigned in-toto v1 Statement bound
// to the single artifact subject. The predicate is either the result file's JSON
// object (passthrough) or a thin SARIF envelope, per predicate-type. commit
// is woven into the scan/v1 envelope only; passthrough predicates ignore it.
func buildStatement(m manifest, subject *intoto.ResourceDescriptor, commit string) (*intoto.Statement, error) {
	pred, err := buildPredicate(m, commit)
	if err != nil {
		return nil, err
	}
	stmt := &intoto.Statement{
		Type:          intoto.StatementTypeUri,
		Subject:       []*intoto.ResourceDescriptor{subject},
		PredicateType: m.PredicateType,
		Predicate:     pred,
	}
	if err := stmt.Validate(); err != nil {
		return nil, fmt.Errorf("statement for %s: %w", m.PredicateType, err)
	}
	return stmt, nil
}

// buildPredicate reads the manifest's result file and shapes it for the
// statement. Passthrough types embed its JSON object; the scan/v1 type wraps
// SARIF in {tool, scannedCommit, result, sarif}. structpb is a map, so the
// predicate is re-encoded and key order is not preserved — the attested bytes
// are not the result file's bytes.
func buildPredicate(m manifest, commit string) (*structpb.Struct, error) {
	raw, err := os.ReadFile(m.resultPath())
	if err != nil {
		return nil, fmt.Errorf("result-file: %w", err)
	}
	switch m.PredicateType {
	case predicateSPDX, predicateOSV, predicateScorecard:
		return jsonObjectToStruct(raw)
	case predicateScanV1:
		var sarif json.RawMessage
		if err := json.Unmarshal(raw, &sarif); err != nil {
			return nil, fmt.Errorf("result-file is not valid JSON: %w", err)
		}
		envelope := map[string]any{
			"tool":          map[string]any{"name": m.Tool.Name, "version": m.Tool.Version},
			"scannedCommit": commit,
			"result":        m.Result,
			"sarif":         sarif,
		}
		enc, err := json.Marshal(envelope)
		if err != nil {
			return nil, err
		}
		return jsonObjectToStruct(enc)
	default:
		// validate() already rejects unknown types; defensive belt-and-braces.
		return nil, fmt.Errorf("unknown predicate-type %q", m.PredicateType)
	}
}

// jsonObjectToStruct decodes a JSON object into a structpb.Struct. A predicate
// MUST be a JSON object (in-toto requires it); a top-level array/scalar fails
// closed rather than producing a malformed statement.
func jsonObjectToStruct(raw []byte) (*structpb.Struct, error) {
	s := &structpb.Struct{}
	if err := protojson.Unmarshal(raw, s); err != nil {
		return nil, fmt.Errorf("predicate must be a JSON object: %w", err)
	}
	return s, nil
}

// marshalStatement renders a Statement as a single compact JSONL line. protojson
// emits the in-toto-canonical field names (`_type`, `predicateType`); compacting
// through encoding/json strips protojson's non-deterministic whitespace so the
// output is one object per line.
func marshalStatement(stmt *intoto.Statement) ([]byte, error) {
	js, err := protojson.Marshal(stmt)
	if err != nil {
		return nil, err
	}
	var canonical any
	if err := json.Unmarshal(js, &canonical); err != nil {
		return nil, err
	}
	return json.Marshal(canonical)
}
