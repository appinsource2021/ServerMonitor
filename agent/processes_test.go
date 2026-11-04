package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func statLine(pid int, name, state string, utime, stime, threads, rss int) string {
	// pid (name) state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime
	// cutime cstime priority nice threads itrealvalue starttime vsize rss
	return fmt.Sprintf("%d (%s) %s 1 1 1 0 -1 0 0 0 0 0 %d %d 0 0 20 0 %d 0 100 1000 %d", pid, name, state, utime, stime, threads, rss)
}

func TestParseProcStatWithAwkwardName(t *testing.T) {
	st, err := parseProcStat(statLine(7, "tmux: (server) x", "S", 30, 12, 4, 250))
	if err != nil {
		t.Fatal(err)
	}
	if st.name != "tmux: (server) x" || st.state != "S" || st.ticks != 42 || st.threads != 4 || st.rss != 250 {
		t.Fatalf("%+v", st)
	}
	if _, err := parseProcStat("garbage"); err == nil {
		t.Fatal("garbage must not parse")
	}
}

func TestBuildProcesses(t *testing.T) {
	old := procRoot
	defer func() { procRoot = old }()
	procRoot = t.TempDir()
	id := strings.Repeat("a", 64)
	write := func(pid int, cmd, cgroup string) {
		d := filepath.Join(procRoot, fmt.Sprint(pid))
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		_ = os.WriteFile(filepath.Join(d, "cmdline"), []byte(cmd), 0o644)
		_ = os.WriteFile(filepath.Join(d, "cgroup"), []byte(cgroup), 0o644)
	}
	write(10, "nginx\x00-g\x00daemon off;\x00", "0::/system.slice/docker-"+id+".scope\n")
	write(11, "mysqld\x00", "0::/system.slice/mysql.service\n")
	write(12, "", "") // kernel thread
	write(13, "", "") // zombie
	write(14, "new\x00", "")

	before := map[int]procStat{
		10: {name: "nginx", state: "S", ticks: 100},
		11: {name: "mysqld", state: "S", ticks: 500},
		12: {name: "kworker", state: "I", ticks: 0},
	}
	after := map[int]procStat{
		10: {name: "nginx", state: "R", ticks: 150, threads: 2, rss: 10},
		11: {name: "mysqld", state: "S", ticks: 510, threads: 9, rss: 1000},
		12: {name: "kworker", state: "I", ticks: 90},
		13: {name: "dead", state: "Z"},
		14: {name: "new", state: "R", ticks: 400},
	}
	page := uint64(os.Getpagesize())
	got, total := buildProcesses(before, after, 200, page*2000, []Container{{ID: id[:12], Name: "web"}})
	if total != 4 || len(got) != 4 {
		t.Fatalf("total %d, got %+v", total, got)
	}
	if got[0].PID != 10 || got[0].CPUPercent != 25 || got[0].Container != "web" || got[0].Command != "nginx -g daemon off;" {
		t.Fatalf("first = %+v", got[0])
	}
	if got[1].PID != 11 || got[1].CPUPercent != 5 || got[1].MemPercent != 50 || got[1].Container != "" {
		t.Fatalf("second = %+v", got[1])
	}
	for _, p := range got {
		if p.PID == 12 {
			t.Fatal("kernel threads are left out")
		}
		if p.PID == 14 && p.CPUPercent != 0 {
			t.Fatalf("a process born during the sample has no measured CPU: %+v", p)
		}
	}
}

func TestProcessesAndServiceActionsAreClosedToMembers(t *testing.T) {
	srv := newFSServer(t)
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := srv.store.Update(func(c *Config) error {
		c.AllowActions = true
		c.Members = []Member{{ID: "m1", Name: "Ana", Role: "admin", PublicKey: base64.StdEncoding.EncodeToString(pub), Scopes: []string{"*"}}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for i, c := range []struct{ method, path string }{{"GET", "/v1/processes"}, {"POST", "/v1/services/nginx/restart"}} {
		req := RelayRequest{ID: "r", MemberID: "m1", Method: c.method, Path: c.path, TS: time.Now().Unix(), Nonce: strings.Repeat("n", 16) + fmt.Sprint(i)}
		req.Sig = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, signingString(req.Method, req.Path, req.TS, req.Nonce, req.Body)))
		if rep := srv.HandleMember(t.Context(), req); rep.Status != 403 {
			t.Fatalf("%s %s: member must get 403, got %d %s", c.method, c.path, rep.Status, rep.Body)
		}
	}
}
