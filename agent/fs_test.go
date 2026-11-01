package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newFSServer(t *testing.T) *Server {
	t.Helper()
	store, err := LoadConfig(filepath.Join(t.TempDir(), "c.json"))
	if err != nil {
		t.Fatal(err)
	}
	return &Server{store: store, collector: NewCollector(store), alerts: NewAlertEngine(nil),
		docker: NewDockerClient("/nonexistent.sock"), nonces: nonceCache{seen: map[string]time.Time{}}}
}

func fsCall(t *testing.T, h http.Handler, method, path string, body any) (int, map[string]any) {
	t.Helper()
	var rd *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	} else {
		rd = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, rd)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	var out map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func q(p string) string { return url.QueryEscape(p) }

func TestFSDenyList(t *testing.T) {
	for _, p := range []string{"/", "/proc", "/proc/1", "/sys/kernel", "/dev/null", "/boot/grub", "/usr", "/usr/share/x",
		"/bin/sh", "/sbin/init", "/lib", "/lib64/x", "/lib32", "/etc/srvmon", "/etc/srvmon/config.json", "/usr/local/bin/srvmon-agent", "/run/srvmon/agent.sock"} {
		if fsProtected(p) == "" {
			t.Errorf("%s should be protected", p)
		}
	}
	for _, p := range []string{"/var/www/old", "/etc/nginx/nginx.conf", "/home/x/.cache", "/opt/app", "/libre/x", "/etc/srvmon2"} {
		if r := fsProtected(p); r != "" {
			t.Errorf("%s should be allowed, got %q", p, r)
		}
	}
	// delete-only rules
	for _, p := range []string{"/var", "/etc", "/home", "/var/lib/docker", "/var/lib/docker/overlay2"} {
		if fsUndeletable(p) == "" {
			t.Errorf("%s should not be deletable", p)
		}
	}
	if fsUndeletable("/var/www") != "" || fsUndeletable("/var/lib/dockerx") != "" {
		t.Error("second-level paths must be deletable")
	}
	if !fsUnreadable("/proc/1/status") || fsUnreadable("/procx") || fsUnreadable("/etc/hosts") {
		t.Error("read deny list wrong")
	}

	// a symlink into a protected tree is caught
	dir := t.TempDir()
	link := filepath.Join(dir, "link")
	if err := os.Symlink("/usr", link); err != nil {
		t.Fatal(err)
	}
	if fsProtected(link) == "" || fsProtected(filepath.Join(link, "share")) == "" {
		t.Error("symlink into /usr should be protected")
	}
	if fsProtected(filepath.Join(dir, "plain.txt")) != "" {
		t.Error("a plain file in a temp dir is allowed")
	}
}

func TestFSListAndRead(t *testing.T) {
	srv := newFSServer(t)
	h := srv.Handler()
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "sub"), 0o755)
	os.WriteFile(filepath.Join(dir, "b.txt"), []byte("hello\nworld\n"), 0o640)
	os.WriteFile(filepath.Join(dir, "a.bin"), []byte{0, 1, 2, 3}, 0o600)
	os.Symlink("b.txt", filepath.Join(dir, "lnk"))

	code, out := fsCall(t, h, "GET", "/v1/fs/list?path="+q(dir), nil)
	if code != 200 {
		t.Fatalf("list %d %v", code, out)
	}
	ents := out["entries"].([]any)
	if len(ents) != 4 {
		t.Fatalf("want 4 entries, got %v", ents)
	}
	first := ents[0].(map[string]any)
	if first["type"] != "dir" || first["name"] != "sub" {
		t.Fatalf("dirs first: %v", first)
	}
	byName := map[string]map[string]any{}
	for _, e := range ents {
		m := e.(map[string]any)
		byName[m["name"].(string)] = m
	}
	if byName["b.txt"]["bytes"].(float64) != 12 || byName["b.txt"]["owner"] == "" || !strings.HasPrefix(byName["b.txt"]["mode"].(string), "-rw-r-----") {
		t.Fatalf("b.txt: %v", byName["b.txt"])
	}
	if byName["lnk"]["type"] != "symlink" || byName["lnk"]["target"] != "b.txt" || byName["lnk"]["bytes"].(float64) != 12 {
		t.Fatalf("lnk: %v", byName["lnk"])
	}
	if out["parent"] != filepath.Dir(dir) {
		t.Fatalf("parent %v", out["parent"])
	}

	code, out = fsCall(t, h, "GET", "/v1/fs/read?path="+q(filepath.Join(dir, "b.txt")), nil)
	if code != 200 || out["content"] != "hello\nworld\n" || out["editable"] != true || out["sha256"] != sha256Hex([]byte("hello\nworld\n")) {
		t.Fatalf("read %d %v", code, out)
	}
	code, out = fsCall(t, h, "GET", "/v1/fs/read?path="+q(filepath.Join(dir, "a.bin")), nil)
	if code != 200 || out["binary"] != true || out["content"] != "" || out["editable"] != false {
		t.Fatalf("binary read %d %v", code, out)
	}
	if code, _ := fsCall(t, h, "GET", "/v1/fs/read?path="+q(dir), nil); code != 400 {
		t.Fatalf("reading a dir should be 400, got %d", code)
	}
	if code, _ := fsCall(t, h, "GET", "/v1/fs/list?path=/proc", nil); code != 403 {
		t.Fatalf("listing /proc should be 403, got %d", code)
	}
	if code, _ := fsCall(t, h, "GET", "/v1/fs/list?path=relative", nil); code != 400 {
		t.Fatalf("relative path should be 400, got %d", code)
	}
}

func TestFSReadTailOfBigFile(t *testing.T) {
	srv := newFSServer(t)
	h := srv.Handler()
	p := filepath.Join(t.TempDir(), "big.log")
	var b strings.Builder
	for i := 0; b.Len() < fsMaxRead+5000; i++ {
		b.WriteString("line number ")
		b.WriteString(strings.Repeat("x", 50))
		b.WriteString("\n")
	}
	os.WriteFile(p, []byte(b.String()), 0o644)
	code, out := fsCall(t, h, "GET", "/v1/fs/read?path="+q(p), nil)
	if code != 200 || out["truncated"] != true || out["editable"] != false || out["sha256"] != nil {
		t.Fatalf("%d %v", code, out["truncated"])
	}
	c := out["content"].(string)
	if len(c) > fsMaxRead || !strings.HasPrefix(c, "line number ") || !strings.HasSuffix(c, "\n") {
		t.Fatalf("tail should start on a line boundary, got %d bytes starting %q", len(c), c[:20])
	}
}

func TestFSWriteBackupAtomicAndConflict(t *testing.T) {
	srv := newFSServer(t)
	h := srv.Handler()
	dir := t.TempDir()
	p := filepath.Join(dir, "app.conf")
	os.WriteFile(p, []byte("a=1\n"), 0o640)

	// stale hash → 409, nothing changes
	code, out := fsCall(t, h, "PUT", "/v1/fs/write", map[string]any{"path": p, "content": "a=2\n", "expect_sha256": "deadbeef"})
	if code != 409 || out["sha256"] != sha256Hex([]byte("a=1\n")) {
		t.Fatalf("conflict %d %v", code, out)
	}
	if b, _ := os.ReadFile(p); string(b) != "a=1\n" {
		t.Fatal("conflict must not write")
	}
	// missing hash on an existing file → 400
	if code, _ := fsCall(t, h, "PUT", "/v1/fs/write", map[string]any{"path": p, "content": "x"}); code != 400 {
		t.Fatalf("missing hash should be 400, got %d", code)
	}
	// correct hash → written, backup kept, mode preserved
	code, out = fsCall(t, h, "PUT", "/v1/fs/write", map[string]any{"path": p, "content": "a=2\n", "expect_sha256": sha256Hex([]byte("a=1\n"))})
	if code != 200 || out["sha256"] != sha256Hex([]byte("a=2\n")) {
		t.Fatalf("write %d %v", code, out)
	}
	if b, _ := os.ReadFile(p); string(b) != "a=2\n" {
		t.Fatal("content not written")
	}
	fi, _ := os.Stat(p)
	if fi.Mode().Perm() != 0o640 {
		t.Fatalf("mode changed to %v", fi.Mode())
	}
	bak := out["backup"].(string)
	if !strings.HasPrefix(bak, p+".srvmon-bak-") {
		t.Fatalf("backup name %q", bak)
	}
	if b, _ := os.ReadFile(bak); string(b) != "a=1\n" {
		t.Fatal("backup has wrong content")
	}
	if tmps, _ := filepath.Glob(filepath.Join(dir, ".srvmon-tmp-*")); len(tmps) != 0 {
		t.Fatal("temp file left behind")
	}
	// only fsKeepBak backups survive
	for i := 0; i < fsKeepBak+2; i++ {
		cur, _ := os.ReadFile(p)
		next := "a=" + string(rune('3'+i)) + "\n"
		if code, out := fsCall(t, h, "PUT", "/v1/fs/write", map[string]any{"path": p, "content": next, "expect_sha256": sha256Hex(cur)}); code != 200 {
			t.Fatalf("write %d: %d %v", i, code, out)
		}
	}
	if baks, _ := filepath.Glob(p + ".srvmon-bak-*"); len(baks) != fsKeepBak {
		t.Fatalf("want %d backups, got %d", fsKeepBak, len(baks))
	}

	// new file needs create=true; then no backup
	np := filepath.Join(dir, "new.txt")
	if code, _ := fsCall(t, h, "PUT", "/v1/fs/write", map[string]any{"path": np, "content": "n"}); code != 404 {
		t.Fatalf("new file without create should be 404, got %d", code)
	}
	code, out = fsCall(t, h, "PUT", "/v1/fs/write", map[string]any{"path": np, "content": "n", "create": true})
	if code != 200 || out["created"] != true {
		t.Fatalf("create %d %v", code, out)
	}
	// protected and oversized
	if code, _ := fsCall(t, h, "PUT", "/v1/fs/write", map[string]any{"path": "/usr/share/x", "content": "n", "create": true}); code != 403 {
		t.Fatalf("protected write should be 403, got %d", code)
	}
	if code, _ := fsCall(t, h, "PUT", "/v1/fs/write", map[string]any{"path": np, "content": strings.Repeat("x", fsMaxEdit+1), "expect_sha256": sha256Hex([]byte("n"))}); code != 413 {
		t.Fatalf("oversized write should be 413, got %d", code)
	}
	// writing through a symlink keeps the link and changes the target
	lnk := filepath.Join(dir, "link.conf")
	os.Symlink(p, lnk)
	cur, _ := os.ReadFile(p)
	if code, out := fsCall(t, h, "PUT", "/v1/fs/write", map[string]any{"path": lnk, "content": "via-link\n", "expect_sha256": sha256Hex(cur)}); code != 200 {
		t.Fatalf("symlink write %d %v", code, out)
	}
	if fi, _ := os.Lstat(lnk); fi.Mode()&os.ModeSymlink == 0 {
		t.Fatal("symlink was replaced")
	}
	if b, _ := os.ReadFile(p); string(b) != "via-link\n" {
		t.Fatal("target not written through the link")
	}
}

func TestFSDelete(t *testing.T) {
	srv := newFSServer(t)
	h := srv.Handler()
	dir := t.TempDir()
	tree := filepath.Join(dir, "old")
	os.MkdirAll(filepath.Join(tree, "deep"), 0o755)
	os.WriteFile(filepath.Join(tree, "x"), bytes.Repeat([]byte("a"), 1000), 0o644)
	os.WriteFile(filepath.Join(tree, "deep", "y"), bytes.Repeat([]byte("b"), 500), 0o644)
	outside := filepath.Join(dir, "keep.txt")
	os.WriteFile(outside, []byte("keep"), 0o644)
	os.Symlink(outside, filepath.Join(tree, "lnk")) // must not follow

	code, out := fsCall(t, h, "DELETE", "/v1/fs?path="+q(tree), nil)
	if code != 200 || out["freed_bytes"].(float64) != 1500 || out["entries"].(float64) != 5 {
		t.Fatalf("delete %d %v", code, out)
	}
	if _, err := os.Stat(tree); !os.IsNotExist(err) {
		t.Fatal("tree still there")
	}
	if _, err := os.Stat(outside); err != nil {
		t.Fatal("symlink target was deleted")
	}
	code, out = fsCall(t, h, "DELETE", "/v1/fs?path="+q(outside), nil)
	if code != 200 || out["freed_bytes"].(float64) != 4 {
		t.Fatalf("file delete %d %v", code, out)
	}
	if code, _ := fsCall(t, h, "DELETE", "/v1/fs?path="+q(outside), nil); code != 404 {
		t.Fatalf("missing file should be 404, got %d", code)
	}
	for _, p := range []string{"/", "/usr", "/var", "/etc/srvmon", "/var/lib/docker"} {
		if code, _ := fsCall(t, h, "DELETE", "/v1/fs?path="+q(p), nil); code != 403 {
			t.Fatalf("delete %s should be 403, got %d", p, code)
		}
	}
}

func TestFSInUseMatching(t *testing.T) {
	m := map[string]string{"/srv/app/data": "mounted into container app", "/home/u/proj": "working directory of bash"}
	if fsUsedBy("/srv/app", m) == "" || fsUsedBy("/srv/app/data/x.db", m) == "" || fsUsedBy("/home/u/proj", m) == "" {
		t.Error("containing, inside and exact paths are in use")
	}
	if fsUsedBy("/srv/application", m) != "" || fsUsedBy("/home/u/projects", m) != "" || fsUsedBy("/var", m) != "" {
		t.Error("siblings with a common prefix are not in use")
	}
}

func TestFSRelayMemberGets403(t *testing.T) {
	srv := newFSServer(t)
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	_, err := srv.store.Update(func(c *Config) error {
		c.Members = []Member{{ID: "m1", Name: "Ana", Role: "admin", PublicKey: base64.StdEncoding.EncodeToString(pub), Scopes: []string{"*"}}}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for i, call := range []struct{ method, path, body string }{
		{"GET", "/v1/fs/list?path=/tmp", ""},
		{"GET", "/v1/fs/read?path=/etc/hostname", ""},
		{"PUT", "/v1/fs/write", `{"path":"/tmp/x","content":"y","create":true}`},
		{"DELETE", "/v1/fs?path=/tmp/x", ""},
	} {
		req := RelayRequest{ID: "r", MemberID: "m1", Method: call.method, Path: call.path, Body: call.body,
			TS: time.Now().Unix(), Nonce: strings.Repeat("n", 16) + string(rune('a'+i))}
		req.Sig = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, signingString(req.Method, req.Path, req.TS, req.Nonce, req.Body)))
		rep := srv.HandleMember(t.Context(), req)
		if rep.Status != 403 || !strings.Contains(rep.Body, "not allowed") {
			t.Fatalf("%s %s: member got %d %s", call.method, call.path, rep.Status, rep.Body)
		}
	}
	// and an admin over SSH is served
	h := srv.Handler()
	if code, _ := fsCall(t, h, "GET", "/v1/fs/list?path="+q(t.TempDir()), nil); code != 200 {
		t.Fatalf("admin list should be 200, got %d", code)
	}
}
