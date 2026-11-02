package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A fake "binary": a shell script that prints a version.
func fakeAgent(t *testing.T, dir, name, version string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n[ \"$1\" = version ] && echo "+version+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestAgentUpdateSwapsBinaryAndKeepsPrev(t *testing.T) {
	if _, err := os.Stat("/bin/sh"); err != nil {
		t.Skip("needs /bin/sh")
	}
	dir := t.TempDir()
	old := fsUploadDir
	fsUploadDir = filepath.Join(dir, "uploads")
	defer func() { fsUploadDir = old }()
	if err := os.MkdirAll(fsUploadDir, 0o700); err != nil {
		t.Fatal(err)
	}
	target := fakeAgent(t, dir, "srvmon-agent", "0.3.5")
	temp := fakeAgent(t, fsUploadDir, "abcdefgh1234", "0.3.6")

	v, err := agentVersionOf(context.Background(), temp)
	if err != nil || v != "0.3.6" {
		t.Fatalf("version: %q %v", v, err)
	}
	if _, err := replaceAgentBinary(context.Background(), temp, target); err != nil {
		t.Fatal(err)
	}
	if v, _ := agentVersionOf(context.Background(), target); v != "0.3.6" {
		t.Fatalf("target not replaced: %q", v)
	}
	if v, _ := agentVersionOf(context.Background(), target+".prev"); v != "0.3.5" {
		t.Fatalf("old binary not kept: %q", v)
	}
	if _, err := os.Stat(temp); err == nil {
		t.Fatal("upload must be removed after the swap")
	}
}

func TestAgentUpdateRefusesBadInput(t *testing.T) {
	dir := t.TempDir()
	old := fsUploadDir
	fsUploadDir = filepath.Join(dir, "uploads")
	defer func() { fsUploadDir = old }()
	if err := os.MkdirAll(fsUploadDir, 0o700); err != nil {
		t.Fatal(err)
	}
	restarts := 0
	oldRestart := agentRestart
	agentRestart = func() error { restarts++; return nil }
	defer func() { agentRestart = oldRestart }()
	srv := newFSServer(t)
	h := srv.Handler()
	body := func(temp, sum string) map[string]any { return map[string]any{"temp": temp, "sha256": sum} }

	// not an upload path
	if code, out := fsCall(t, h, "POST", "/v1/agent/update", body("/etc/passwd", hex64("a"))); code != 400 {
		t.Fatalf("outside upload dir: %d %v", code, out)
	}
	// missing file
	temp := filepath.Join(fsUploadDir, "zzzzzzzz0000")
	if code, _ := fsCall(t, h, "POST", "/v1/agent/update", body(temp, hex64("a"))); code != 400 {
		t.Fatalf("missing file: %d", code)
	}
	// wrong hash
	fakeAgent(t, fsUploadDir, "zzzzzzzz0000", "0.3.6")
	if code, out := fsCall(t, h, "POST", "/v1/agent/update", body(temp, hex64("a"))); code != 409 {
		t.Fatalf("hash mismatch: %d %v", code, out)
	}
	// right hash but not a binary that prints a version
	if err := os.WriteFile(temp, []byte("#!/bin/sh\necho hello\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	sum, _ := fileSHA256(temp)
	if code, out := fsCall(t, h, "POST", "/v1/agent/update", body(temp, sum)); code != 400 {
		t.Fatalf("bad binary: %d %v", code, out)
	}
	if restarts != 0 {
		t.Fatal("no restart may be scheduled on a refused update")
	}
	// team members never reach it, not even admins
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := srv.store.Update(func(c *Config) error {
		c.Members = []Member{{ID: "m1", Name: "Ana", Role: "admin", PublicKey: base64.StdEncoding.EncodeToString(pub), Scopes: []string{"*"}}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	req := RelayRequest{ID: "r", MemberID: "m1", Method: "POST", Path: "/v1/agent/update", Body: `{"temp":"x","sha256":"y"}`,
		TS: time.Now().Unix(), Nonce: strings.Repeat("n", 17)}
	req.Sig = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, signingString(req.Method, req.Path, req.TS, req.Nonce, req.Body)))
	if rep := srv.HandleMember(t.Context(), req); rep.Status != 403 {
		t.Fatalf("member must get 403, got %d %s", rep.Status, rep.Body)
	}
}

func hex64(c string) string {
	s := ""
	for len(s) < 64 {
		s += c
	}
	return s
}
