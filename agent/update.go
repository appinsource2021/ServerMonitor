package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Self-update (agent >= 0.3.6). The app uploads the new binary into the upload
// folder (over SFTP, as whatever user it logs in with) and calls
//
//	POST /v1/agent/update {"temp": "/var/lib/srvmon/upload/<id>", "sha256": "<hex>"}
//
// The agent checks the hash, runs `<temp> version`, keeps the old binary as
// <path>.prev, swaps the file in and restarts itself a moment after answering.
// This is how a server the app cannot reach as root (a `srvmon` login) still
// gets updates from the phone. The unit has ProtectSystem=full, so the swap and
// the restart run as transient units through systemd-run, outside the sandbox.

var agentVersionRe = regexp.MustCompile(`^\d+\.\d+(\.\d+)?([-+][0-9A-Za-z.-]+)?$`)

// agentRestart is replaced in tests.
var agentRestart = func() error {
	return exec.Command("systemd-run", "--quiet", "--collect", "--on-active=2",
		"--unit", fmt.Sprintf("srvmon-agent-restart-%d", time.Now().Unix()),
		"systemctl", "restart", "srvmon-agent").Run()
}

func (s *Server) agentUpdate(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Temp   string `json:"temp"`
		SHA256 string `json:"sha256"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if filepath.Dir(in.Temp) != fsUploadDir || !fsUploadNameRe.MatchString(filepath.Base(in.Temp)) {
		writeErr(w, 400, "temp must be a path from /v1/fs/upload")
		return
	}
	want := strings.ToLower(strings.TrimSpace(in.SHA256))
	if len(want) != 64 {
		writeErr(w, 400, "sha256 must be 64 hex characters")
		return
	}
	fi, err := os.Lstat(in.Temp)
	if err != nil || !fi.Mode().IsRegular() {
		writeErr(w, 400, "uploaded file not found")
		return
	}
	got, err := fileSHA256(in.Temp)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	if got != want {
		writeErr(w, 409, "checksum mismatch: the upload is damaged or not the file the app meant")
		return
	}
	if err := os.Chmod(in.Temp, 0o755); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	newVersion, err := agentVersionOf(ctx, in.Temp)
	if err != nil {
		_ = os.Remove(in.Temp)
		writeErr(w, 400, "the uploaded file does not run here: "+err.Error())
		return
	}
	self, err := os.Executable()
	if err == nil {
		self, err = filepath.EvalSymlinks(self)
	}
	if err != nil {
		writeErr(w, 500, "cannot find my own binary: "+err.Error())
		return
	}
	if out, err := replaceAgentBinary(ctx, in.Temp, self); err != nil {
		writeErr(w, 500, "install failed: "+err.Error()+strings.TrimSpace(" "+out))
		return
	}
	if err := agentRestart(); err != nil {
		writeErr(w, 500, "binary replaced ("+newVersion+") but the restart could not be scheduled: "+err.Error()+". Run: systemctl restart srvmon-agent")
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "from": version, "to": newVersion, "path": self, "restart_in_seconds": 2})
}

func fileSHA256(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// agentVersionOf runs `<bin> version` and accepts only something that looks like a version.
func agentVersionOf(ctx context.Context, bin string) (string, error) {
	out, err := killableCmd(ctx, bin, "version").Output()
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(string(out))
	if !agentVersionRe.MatchString(v) {
		return "", fmt.Errorf("unexpected output %q", v)
	}
	return v, nil
}

// replaceAgentBinary keeps the old file as <target>.prev and swaps the new one in
// with a rename, so the path is never half-written. Through systemd-run when
// available (the service's own sandbox cannot write /usr), directly otherwise.
func replaceAgentBinary(ctx context.Context, temp, target string) (string, error) {
	script := fmt.Sprintf("set -e; cp -p %s %s.prev 2>/dev/null || true; install -m 755 %s %s.new && mv -f %s.new %s && rm -f %s",
		shellQuote(target), shellQuote(target), shellQuote(temp), shellQuote(target), shellQuote(target), shellQuote(target), shellQuote(temp))
	var cmd *exec.Cmd
	if _, err := exec.LookPath("systemd-run"); err == nil {
		cmd = killableCmd(ctx, "systemd-run", "--quiet", "--collect", "--wait", "--pipe",
			"--unit", fmt.Sprintf("srvmon-agent-update-%d", time.Now().UnixNano()), "/bin/sh", "-c", script)
	} else {
		cmd = killableCmd(ctx, "/bin/sh", "-c", script)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return string(out), errors.New("timed out")
		}
		return string(out), err
	}
	return string(out), nil
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
