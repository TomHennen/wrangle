package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/carabiner-dev/signer"
	"github.com/carabiner-dev/signer/options"
)

// statementSigner signs one in-toto statement and returns its canonical
// serialized bundle/envelope bytes. Mirrors `bnd statement`: one shared
// Signer across statements so the OIDC + Fulcio flow runs once.
type statementSigner interface {
	sign(statement []byte) ([]byte, error)
}

// newSigner builds the shared signer for --sign and a closer to release it.
// Overridden by the hermetic unit test with a local-key signer.
var newSigner = func() (statementSigner, func(), error) {
	ks, err := newKeylessSigner()
	if err != nil {
		return nil, nil, err
	}
	return ks, func() { _ = ks.close() }, nil
}

// newRetrySigner builds the shared signer, retrying construction once and
// wrapping it so each sign call is retried once. The retry covers ONLY
// Sigstore I/O — never statement building, digesting, manifest parsing, or
// file writes — so it can flip a transient failure but never manufacture
// output.
func newRetrySigner(stderr io.Writer) (statementSigner, func(), error) {
	sg, closeFn, err := newSigner()
	if err != nil {
		retryNotice(stderr, "signer construction", err)
		retrySleep()
		sg, closeFn, err = newSigner()
		if err != nil {
			return nil, nil, err
		}
	}
	return &retrySigner{inner: sg, stderr: stderr}, closeFn, nil
}

// retrySigner retries each sign call once to absorb a transient Sigstore blip
// (signing is deterministic input -> Fulcio/Rekor I/O, so a retry re-signs the
// same bytes).
type retrySigner struct {
	inner  statementSigner
	stderr io.Writer
}

func (r *retrySigner) sign(statement []byte) ([]byte, error) {
	out, err := r.inner.sign(statement)
	if err == nil {
		return out, nil
	}
	retryNotice(r.stderr, "signing statement", err)
	retrySleep()
	return r.inner.sign(statement)
}

func retryNotice(stderr io.Writer, what string, err error) {
	fmt.Fprintf(stderr, "wrangle-attest: %s failed (%v); retrying once for transient Sigstore I/O\n", what, err)
}

// retrySleep spaces the attempts by WRANGLE_RETRY_DELAY seconds (default 5;
// tests set 0).
func retrySleep() {
	delay := 5 * time.Second
	if v := os.Getenv("WRANGLE_RETRY_DELAY"); v != "" {
		if s, err := strconv.Atoi(v); err == nil && s >= 0 {
			delay = time.Duration(s) * time.Second
		}
	}
	time.Sleep(delay)
}

// keylessSigner is the production sigstore backend: ambient GitHub OIDC ->
// Fulcio cert -> Rekor, producing a Sigstore bundle byte-identical to
// `bnd statement`.
type keylessSigner struct {
	sg *signer.Signer
}

// newKeylessSigner builds the shared sigstore signer from the bnd defaults.
func newKeylessSigner() (*keylessSigner, error) {
	sg, err := signer.NewSignerFromSet(options.DefaultSignerSet())
	if err != nil {
		return nil, fmt.Errorf("building signer: %w", err)
	}
	return &keylessSigner{sg: sg}, nil
}

func (k *keylessSigner) sign(statement []byte) ([]byte, error) {
	art, err := k.sg.SignStatement(statement)
	if err != nil {
		return nil, fmt.Errorf("signing statement: %w", err)
	}
	var buf bytes.Buffer
	if _, err := art.WriteTo(&buf); err != nil {
		return nil, fmt.Errorf("serializing signed statement: %w", err)
	}
	return buf.Bytes(), nil
}

func (k *keylessSigner) close() error { return k.sg.Close() }
