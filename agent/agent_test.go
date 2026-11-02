package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestParseCPUAndPercent(t *testing.T) {
	a, err := parseCPUTimes(strings.NewReader("cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 2 3 4\n"))
	if err != nil {
		t.Fatal(err)
	}
	if a.Total != 1000 || a.Idle != 800 {
		t.Fatalf("got %+v", a)
	}
	b := CPUTimes{Idle: 900, Total: 1500}
	if p := cpuPercent(a, b); p != 80 {
		t.Fatalf("cpu%% = %v, want 80", p)
	}
	if p := cpuPercent(b, a); p != 0 {
		t.Fatalf("counter reset should give 0, got %v", p)
	}
}

func TestParseMeminfo(t *testing.T) {
	m, err := parseMeminfo(strings.NewReader("MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 250 kB\nSwapTotal: 100 kB\nSwapFree: 40 kB\n"))
	if err != nil {
		t.Fatal(err)
	}
	if m.TotalBytes != 1024000 || m.UsedBytes != 750*1024 || m.Percent != 75 || m.SwapUsedBytes != 60*1024 {
		t.Fatalf("got %+v", m)
	}
}

func TestParseNetDevSkipsVirtual(t *testing.T) {
	in := `Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 999 1 0 0 0 0 0 0 999 1 0 0 0 0 0 0
  eth0: 1000 1 0 0 0 0 0 0 2000 1 0 0 0 0 0 0
vethab: 5000 1 0 0 0 0 0 0 5000 1 0 0 0 0 0 0
docker0: 5000 1 0 0 0 0 0 0 5000 1 0 0 0 0 0 0
`
	c := parseNetDev(strings.NewReader(in))
	if c.RxBytes != 1000 || c.TxBytes != 2000 {
		t.Fatalf("got %+v", c)
	}
}

func TestLoadavgAndOSRelease(t *testing.T) {
	l, err := parseLoadavg("7.84 6.10 3.92 3/812 12345\n")
	if err != nil || l != [3]float64{7.84, 6.10, 3.92} {
		t.Fatalf("got %v %v", l, err)
	}
	if s := parseOSRelease("NAME=\"Ubuntu\"\nPRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\n"); s != "Ubuntu 24.04.1 LTS" {
		t.Fatalf("got %q", s)
	}
}

func frame(stream byte, s string) []byte {
	h := make([]byte, 8)
	h[0] = stream
	binary.BigEndian.PutUint32(h[4:], uint32(len(s)))
	return append(h, s...)
}

func TestDemuxLogs(t *testing.T) {
	var buf bytes.Buffer
	buf.Write(frame(1, "2026-10-30T14:02:11.000000001Z worker started\n2026-10-30T14:02:12.0Z conn"))
	buf.Write(frame(2, "2026-10-30T14:08:16.5Z killed: out of memory\n"))
	buf.Write(frame(1, "ected\n"))
	lines, err := demuxLogs(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 3 {
		t.Fatalf("want 3 lines, got %d: %+v", len(lines), lines)
	}
	if lines[0].Text != "worker started" || lines[0].Time != "2026-10-30T14:02:11.000000001Z" {
		t.Fatalf("line 0: %+v", lines[0])
	}
	if lines[1].Stream != "stderr" || lines[1].Text != "killed: out of memory" {
		t.Fatalf("line 1: %+v", lines[1])
	}
	if lines[2].Text != "connected" {
		t.Fatalf("split frame not joined: %+v", lines[2])
	}
}

func TestParseListUnits(t *testing.T) {
	in := "ssh.service loaded active running OpenBSD Secure Shell server\n" +
		"● backup.service loaded failed failed Nightly backup\n" +
		"ghost.service not-found inactive dead ghost.service\n"
	s := parseListUnits(in)
	if len(s) != 2 || s[1].Name != "backup.service" || s[1].Active != "failed" || s[0].Description != "OpenBSD Secure Shell server" {
		t.Fatalf("got %+v", s)
	}
	if unitNameRe.MatchString("-x") || unitNameRe.MatchString("a;rm") || !unitNameRe.MatchString("getty@tty1.service") {
		t.Fatal("unit name validation wrong")
	}
}

func TestContainerMath(t *testing.T) {
	p := containerCPUPercent(cpuSample{1000, 10000}, cpuSample{2820, 18000}, 8)
	if p != 182 {
		t.Fatalf("cpu = %v", p)
	}
	var st statsResult
	st.MemoryStats.Usage = 1000
	st.MemoryStats.Stats = map[string]uint64{"inactive_file": 300}
	if containerMemUsage(st) != 700 {
		t.Fatal("mem v2")
	}
}

func TestContainerDown(t *testing.T) {
	now := time.Now()
	recent := now.Add(-time.Minute).Format(time.RFC3339Nano)
	old := now.Add(-48 * time.Hour).Format(time.RFC3339Nano)
	cases := []struct {
		c    Container
		want bool
	}{
		{Container{State: "exited", ExitCode: 137, FinishedAt: recent}, true},
		{Container{State: "exited", ExitCode: 0, FinishedAt: recent}, false},
		{Container{State: "exited", ExitCode: 143, FinishedAt: recent}, false},
		{Container{State: "exited", ExitCode: 0, OOMKilled: true, FinishedAt: recent}, true},
		{Container{State: "exited", ExitCode: 1, FinishedAt: old}, false},
		{Container{State: "dead"}, true},
		{Container{State: "running"}, false},
	}
	for i, tc := range cases {
		if got := containerDown(tc.c, now); got != tc.want {
			t.Errorf("case %d: got %v want %v", i, got, tc.want)
		}
	}
}

type recorder struct {
	mu sync.Mutex
	n  []Notification
}

func (r *recorder) Notify(n Notification) { r.mu.Lock(); r.n = append(r.n, n); r.mu.Unlock() }

func TestAlertEngineHoldCooldownResolve(t *testing.T) {
	rec := &recorder{}
	e := NewAlertEngine(rec)
	cfg := DefaultConfig()
	cfg.Name = "staging-01"
	t0 := time.Unix(1_800_000_000, 0)
	hot := Snapshot{CPUPercent: 96, Memory: MemInfo{TotalBytes: 1, Percent: 10}}

	e.Evaluate(t0, hot, cfg)
	if len(e.Active()) != 0 || len(rec.n) != 0 {
		t.Fatal("should wait for_seconds before firing")
	}
	e.Evaluate(t0.Add(301*time.Second), hot, cfg)
	if a := e.Active(); len(a) != 1 || a[0].Severity != "critical" || a[0].Server != "staging-01" {
		t.Fatalf("active = %+v", a)
	}
	if len(rec.n) != 1 {
		t.Fatalf("want 1 push, got %d", len(rec.n))
	}
	e.Evaluate(t0.Add(310*time.Second), hot, cfg) // still firing: no repeat
	if len(rec.n) != 1 {
		t.Fatal("repeated push while active")
	}
	cool := hot
	cool.CPUPercent = 20
	e.Evaluate(t0.Add(320*time.Second), cool, cfg)
	if len(e.Active()) != 0 || len(e.History()) != 1 {
		t.Fatal("should resolve")
	}
	if len(rec.n) != 2 || !rec.n[1].Resolved {
		t.Fatalf("want resolved push, got %+v", rec.n)
	}
	// flaps back within cooldown: becomes active but no new push
	e.Evaluate(t0.Add(330*time.Second), hot, cfg)
	e.Evaluate(t0.Add(640*time.Second), hot, cfg)
	if len(e.Active()) != 1 || len(rec.n) != 2 {
		t.Fatalf("cooldown not respected: %d pushes", len(rec.n))
	}
}

func TestAlertRestartLoopAndPeer(t *testing.T) {
	rec := &recorder{}
	e := NewAlertEngine(rec)
	cfg := DefaultConfig()
	cfg.Name = "web-02"
	t0 := time.Unix(1_800_000_000, 0)
	for i := 0; i < 4; i++ {
		s := Snapshot{Containers: []Container{{Name: "pdf-renderer", State: "restarting", RestartCount: i * 2}}}
		e.Evaluate(t0.Add(time.Duration(i)*time.Minute), s, cfg)
	}
	found := false
	for _, a := range e.Active() {
		if a.Key == "restart_loop:pdf-renderer" {
			found = true
		}
	}
	if !found {
		t.Fatalf("restart loop not detected: %+v", e.Active())
	}

	s := Snapshot{Peers: []PeerStatus{{Peer: Peer{Name: "db-01", Host: "10.0.1.12", Port: 22}, Reachable: false, LastOK: t0}}}
	e.Evaluate(t0.Add(3*time.Minute), s, cfg)
	var peer *Alert
	for _, a := range e.Active() {
		if a.Key == "peer_down:db-01" {
			a := a
			peer = &a
		}
	}
	if peer == nil || peer.Server != "db-01" {
		t.Fatalf("peer alert missing or wrong server: %+v", peer)
	}
}

func TestJWTVerifies(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	k, err := parseP8(pemBytes)
	if err != nil {
		t.Fatal(err)
	}
	tok, err := makeJWT(k, "ABC123DEFG", "TEAM123456", time.Unix(1_800_000_000, 0))
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatal("bad jwt")
	}
	var hdr map[string]string
	hb, _ := base64.RawURLEncoding.DecodeString(parts[0])
	_ = json.Unmarshal(hb, &hdr)
	if hdr["alg"] != "ES256" || hdr["kid"] != "ABC123DEFG" {
		t.Fatalf("header %v", hdr)
	}
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if len(sig) != 64 || !ecdsa.Verify(&key.PublicKey, sum[:], r, s) {
		t.Fatal("signature does not verify")
	}
	if _, err := parseP8([]byte("nope")); err == nil {
		t.Fatal("expected error for bad key")
	}
	if id := collapseID(Notification{Server: strings.Repeat("x", 80), Key: "cpu"}); len(id) > 64 {
		t.Fatal("collapse id too long")
	}
}

func TestConfigRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	s, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Update(func(c *Config) error { c.Name = "db-01"; c.Peers = []Peer{{Name: "web", Host: "1.2.3.4"}}; return nil }); err != nil {
		t.Fatal(err)
	}
	s2, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	c := s2.Get()
	if c.Name != "db-01" || c.Peers[0].Port != 22 || !c.Rules.CPU.Enabled {
		t.Fatalf("got %+v", c)
	}
	if _, err := s2.Update(func(c *Config) error { c.Listen = ":9123"; c.Token = "short"; return nil }); err == nil {
		t.Fatal("short token must be rejected")
	}
}

// End-to-end: daemon handler on a unix socket, driven by the CLI client the app uses.
func TestAPIOverUnixSocketWithCLI(t *testing.T) {
	dir := t.TempDir()
	configPath = filepath.Join(dir, "config.json")
	store, err := LoadConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	sock := filepath.Join(dir, "agent.sock")
	store.Update(func(c *Config) error {
		c.Socket = sock
		c.Name = "test-01"
		c.DockerSocket = filepath.Join(dir, "nodocker.sock")
		return nil
	})
	apns := NewAPNs(store)
	col := NewCollector(store)
	col.collectHost()
	srv := &Server{store: store, collector: col, alerts: NewAlertEngine(nil), apns: apns, docker: NewDockerClient(filepath.Join(dir, "nodocker.sock"))}
	ln, err := listenUnix(sock, "")
	if err != nil {
		t.Fatal(err)
	}
	hs := &http.Server{Handler: srv.Handler()}
	go hs.Serve(ln)
	defer hs.Close()

	call := func(args ...string) (int, string) {
		var out, errb bytes.Buffer
		full := append([]string{"-socket", sock}, args...)
		if rc := runAPIClient(full, strings.NewReader(""), &out, &errb); rc != 0 {
			t.Fatalf("cli rc=%d stderr=%s", rc, errb.String())
		}
		status, body, _ := strings.Cut(out.String(), "\n")
		var code int
		_, _ = fmt.Sscanf(status, "HTTP %d", &code)
		return code, body
	}

	code, body := call("GET", "/v1/health")
	if code != 200 || !strings.Contains(body, `"test-01"`) {
		t.Fatalf("health %d %s", code, body)
	}
	code, body = call("GET", "/v1/summary")
	if code != 200 || !strings.Contains(body, `"status":{"level":"healthy"`) {
		t.Fatalf("summary %d %s", code, body)
	}
	code, _ = call("POST", "/v1/containers/x/restart")
	if code != 403 {
		t.Fatalf("actions must be off by default, got %d", code)
	}
	code, _ = call("POST", "/v1/devices", `{"token":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","env":"development"}`)
	if code != 200 || len(store.Get().Devices) != 1 {
		t.Fatalf("device register %d", code)
	}
	code, _ = call("POST", "/v1/devices", `{"token":"zz;rm","env":"development"}`)
	if code != 400 {
		t.Fatal("bad token accepted")
	}
	code, body = call("PUT", "/v1/rules", `{"cpu":{"enabled":true,"percent":150}}`)
	if code != 400 {
		t.Fatalf("invalid percent accepted: %s", body)
	}
	code, body = call("GET", "/v1/config")
	if code != 200 || strings.Contains(body, "abcdef0123456789abcdef01234567") {
		t.Fatalf("config leaks full token: %s", body)
	}
	code, _ = call("POST", "/v1/push/test")
	if code != 400 {
		t.Fatal("push test without key should be 400")
	}
	if fi, err := os.Stat(sock); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("socket perms %v %v", fi.Mode().Perm(), err)
	}
	var _ net.Conn
}

// Fake Docker Engine on a unix socket to exercise the real client code paths.
func TestDockerCollectAndLogsAgainstFakeEngine(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "docker.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	var statsCalls int
	var mu sync.Mutex
	mux := http.NewServeMux()
	mux.HandleFunc("GET /containers/json", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`[
 {"Id":"aaaaaaaaaaaa1111","Names":["/erp-api"],"Image":"erp-api:2.14","State":"running","Status":"Up 3 days (healthy)","Labels":{"com.docker.compose.project":"erp"},"Ports":[{"PrivatePort":8080,"PublicPort":80,"Type":"tcp"},{"PrivatePort":8080,"PublicPort":80,"Type":"tcp"}]},
 {"Id":"bbbbbbbbbbbb2222","Names":["/erp-worker"],"Image":"erp-worker:2.14.3","State":"exited","Status":"Exited (137) 12 minutes ago","Labels":{},"Ports":[]}
]`))
	})
	mux.HandleFunc("GET /containers/{id}/json", func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.PathValue("id"), "aaaa") {
			w.Write([]byte(`{"RestartCount":0,"State":{"ExitCode":0,"StartedAt":"2026-10-27T10:00:00Z","FinishedAt":"0001-01-01T00:00:00Z","Health":{"Status":"healthy"}},"HostConfig":{"RestartPolicy":{"Name":"unless-stopped"},"Memory":0},"Config":{"Tty":false}}`))
			return
		}
		w.Write([]byte(`{"RestartCount":5,"State":{"OOMKilled":true,"ExitCode":137,"FinishedAt":"2026-10-30T14:08:16Z"},"HostConfig":{"RestartPolicy":{"Name":"on-failure"},"Memory":536870912},"Config":{"Tty":false}}`))
	})
	mux.HandleFunc("GET /containers/{id}/stats", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		statsCalls++
		n := statsCalls
		mu.Unlock()
		total, sys := 1000, 10000
		if n > 1 {
			total, sys = 2820, 18000
		}
		w.Write([]byte(fmt.Sprintf(`{"cpu_stats":{"cpu_usage":{"total_usage":%d},"system_cpu_usage":%d,"online_cpus":8},"memory_stats":{"usage":1500000000,"limit":8000000000,"stats":{"inactive_file":0}}}`, total, sys)))
	})
	mux.HandleFunc("GET /info", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"ServerVersion":"27.3.1","Images":14,"Driver":"overlay2","DockerRootDir":"/var/lib/docker","NCPU":8}`))
	})
	mux.HandleFunc("GET /containers/{id}/logs", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("tail") != "50" || r.URL.Query().Get("timestamps") != "1" {
			w.WriteHeader(400)
			return
		}
		w.Header().Set("Content-Type", "application/vnd.docker.multiplexed-stream")
		w.Write(frame(1, "2026-10-30T14:02:11Z worker started\n"))
		w.Write(frame(2, "2026-10-30T14:08:16Z killed: out of memory\n"))
	})
	hs := &http.Server{Handler: mux}
	go hs.Serve(ln)
	defer hs.Close()

	client := NewDockerClient(sock)
	dc := NewDockerCollector(client)
	ctx := t.Context()
	if _, err := dc.Collect(ctx); err != nil {
		t.Fatal(err)
	}
	list, err := dc.Collect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || list[0].Name != "erp-worker" {
		t.Fatalf("problems must sort first: %+v", list)
	}
	w, a := list[0], list[1]
	if !w.OOMKilled || w.ExitCode != 137 || w.RestartCount != 5 || w.MemLimitBytes != 536870912 || w.ID != "bbbbbbbbbbbb" {
		t.Fatalf("worker: %+v", w)
	}
	if a.CPUPercent != 182 || a.MemBytes != 1500000000 || a.Health != "healthy" || a.ComposeProject != "erp" || len(a.Ports) != 1 || a.FinishedAt != "" {
		t.Fatalf("api: %+v", a)
	}
	lines, err := client.Logs(ctx, "bbbbbbbbbbbb", 50, 0, false)
	if err != nil || len(lines) != 2 || lines[1].Stream != "stderr" {
		t.Fatalf("logs: %+v %v", lines, err)
	}
	info, err := client.Info(ctx)
	if err != nil || info.Version != "27.3.1" || info.Images != 14 || info.StorageDriver != "overlay2" || info.DataRoot != "/var/lib/docker" {
		t.Fatalf("info: %+v %v", info, err)
	}
	// The Docker card's load: only running containers count, CPU as a share of the host.
	cpu, mem := dockerLoad(list, 8)
	if cpu != 22.8 || mem != 1500000000 {
		t.Fatalf("docker load: cpu=%v mem=%v", cpu, mem)
	}
}

func TestDockerLoadClampsAndSkipsStopped(t *testing.T) {
	cs := []Container{
		{State: "running", CPUPercent: 350, MemBytes: 100},
		{State: "running", CPUPercent: 90, MemBytes: 50},
		{State: "exited", CPUPercent: 999, MemBytes: 999},
	}
	if cpu, mem := dockerLoad(cs, 4); cpu != 100 || mem != 150 {
		t.Fatalf("got cpu=%v mem=%v", cpu, mem)
	}
	if cpu, mem := dockerLoad(nil, 0); cpu != 0 || mem != 0 {
		t.Fatalf("empty: cpu=%v mem=%v", cpu, mem)
	}
	if cpu, _ := dockerLoad(cs[:2], 0); cpu != 100 {
		t.Fatalf("unknown cpu count must not divide by zero, got %v", cpu)
	}
}

func TestParseDuAndFind(t *testing.T) {
	du := "1000\t/var/lib/docker\n50\t/var/log\n2000\t/var\n7\t/var/tmp\n"
	e, total := parseDu(du, "/var")
	if total != 2000 || len(e) != 3 || e[0].Name != "docker" || e[2].Bytes != 7 {
		t.Fatalf("du: %v %+v", total, e)
	}
	f := parseFind("100\t/a/x.log\n900\t/b/big.img\nbad\n")
	if len(f) != 2 || f[0].Name != "big.img" {
		t.Fatalf("find: %+v", f)
	}
	if _, err := cleanScanPath("relative"); err == nil {
		t.Fatal("relative path accepted")
	}
	if p, err := cleanScanPath("/tmp/../tmp/"); err != nil || p != "/tmp" {
		t.Fatalf("clean: %q %v", p, err)
	}
}

func TestDiskScanRealDirectory(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "big"), 0o755)
	os.WriteFile(filepath.Join(dir, "big", "blob"), make([]byte, 3<<20), 0o644)
	os.WriteFile(filepath.Join(dir, "small"), []byte("x"), 0o644)
	sc := scanner.Start(dir, true)
	for i := 0; i < 100 && sc.Status == "running"; i++ {
		time.Sleep(50 * time.Millisecond)
		sc, _ = scanner.Get(dir)
	}
	if sc.Status != "done" || len(sc.Entries) == 0 || sc.Entries[0].Name != "big" || sc.Total < 3<<20 {
		t.Fatalf("scan: %+v", sc)
	}
}

func TestHealthCheckRuns(t *testing.T) {
	store, _ := LoadConfig(filepath.Join(t.TempDir(), "c.json"))
	store.Update(func(c *Config) error { c.DockerSocket = "/nonexistent.sock"; return nil })
	col := NewCollector(store)
	srv := &Server{store: store, collector: col, alerts: NewAlertEngine(nil), docker: NewDockerClient("/nonexistent.sock")}
	r := srv.RunHealthCheck(t.Context())
	ids := map[string]string{}
	for _, c := range r.Checks {
		ids[c.ID] = c.Status
	}
	if ids["cpu"] == "" || ids["memory"] == "" || ids["disk:/"] == "" || ids["docker"] != "skip" || ids["agent"] != "ok" {
		t.Fatalf("checks: %+v", r.Checks)
	}
}

func TestDockerDiskUsage(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "d.sock")
	logf := filepath.Join(dir, "c.log")
	os.WriteFile(logf, make([]byte, 4096), 0o644)
	ln, _ := net.Listen("unix", sock)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /system/df", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"LayersSize":5000,"Images":[{"RepoTags":["erp:1"],"Size":3000,"SharedSize":1000,"Containers":1},{"RepoTags":["<none>:<none>"],"Size":2000,"SharedSize":1000,"Containers":0}],
"Containers":[{"Names":["/erp"],"SizeRw":100,"State":"running"},{"Names":["/old"],"SizeRw":40,"State":"exited"}],
"Volumes":[{"Name":"pg","UsageData":{"Size":700,"RefCount":1}},{"Name":"orphan","UsageData":{"Size":300,"RefCount":0}}],
"BuildCache":[{"Size":900,"InUse":false,"Shared":false},{"Size":50,"InUse":true,"Shared":false}]}`))
	})
	mux.HandleFunc("GET /info", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"DockerRootDir":"/var/lib/docker"}`)) })
	mux.HandleFunc("GET /containers/json", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`[{"Id":"aaaaaaaaaaaaaaaa","Names":["/erp"]}]`))
	})
	mux.HandleFunc("GET /containers/{id}/json", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"LogPath":%q}`, logf)
	})
	hs := &http.Server{Handler: mux}
	go hs.Serve(ln)
	defer hs.Close()
	d := NewDockerClient(sock).DiskUsage(t.Context())
	if !d.Available || d.Images.Bytes != 5000 || d.Images.Reclaimable != 1000 || d.Volumes.Reclaimable != 300 ||
		d.BuildCache.Bytes != 950 || d.BuildCache.Reclaimable != 900 || d.Logs.Bytes != 4096 || d.Containers.Reclaimable != 40 ||
		d.TopImages[0].Name != "erp:1" || d.DataRoot != "/var/lib/docker" {
		t.Fatalf("%+v", d)
	}
}

func TestCleanupHelpers(t *testing.T) {
	if parseJournalUsage("Archived and active journals take up 1.5G in the file system.") != uint64(1.5*float64(1<<30)) {
		t.Fatal("journal G")
	}
	if parseJournalUsage("Archived and active journals take up 340.0M in the file system.") != 340<<20 {
		t.Fatal("journal M")
	}
	for n, want := range map[string]bool{"syslog.2": true, "app.log.13": true, "syslog": false, "x.log": false, "a.": false} {
		if isRotatedNumber(n) != want {
			t.Fatalf("rotated %s", n)
		}
	}
	prot := []string{"/var/www/erp", "/srv/x/vendor/lib"}
	if usedBy("/var/www/erp/vendor", prot) == "" || usedBy("/srv/x/vendor", prot) == "" || usedBy("/opt/old/vendor", prot) != "" {
		t.Fatal("usedBy")
	}
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "a", "b"), 0o755)
	os.WriteFile(filepath.Join(dir, "a", "b", "f"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(dir, "g"), []byte("x"), 0o644)
	if err := removeContents(dir); err != nil {
		t.Fatal(err)
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 0 {
		t.Fatal("not emptied")
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatal("cache dir itself must stay")
	}
}

func TestCleanupRefusesUnknownAndUnsafe(t *testing.T) {
	store, _ := LoadConfig(filepath.Join(t.TempDir(), "c.json"))
	srv := &Server{store: store, collector: NewCollector(store), alerts: NewAlertEngine(nil), docker: NewDockerClient("/nonexistent.sock")}
	res, err := srv.CleanupRun(t.Context(), []string{"dir:/etc", "rm-everything"})
	if err != nil || len(res) != 2 || res[0].Error == "" || res[1].Error == "" {
		t.Fatalf("%+v %v", res, err)
	}
	if err := srv.cleanOne(t.Context(), CleanupItem{ID: "dir:/etc"}); err == nil {
		t.Fatal("deleted a non-vendor dir")
	}
}

func TestDiskScanCancel(t *testing.T) {
	dir := t.TempDir()
	scanner.Start(dir, true)
	scanner.Cancel(dir) // may already be done on a tiny dir; then false
	sc, _ := scanner.Get(dir)
	if sc.Status != "cancelled" && sc.Status != "done" {
		t.Fatalf("status %s", sc.Status)
	}
	// a long-running scan is really stopped
	scanner.mu.Lock()
	ctx, cancel := context.WithCancel(context.Background())
	s := &DiskScan{Path: "/fake", Status: "running", StartedAt: time.Now()}
	scanner.scans["/fake"], scanner.cancels["/fake"] = s, cancel
	scanner.mu.Unlock()
	if !scanner.Cancel("/fake") || ctx.Err() == nil {
		t.Fatal("cancel did not stop the context")
	}
	if got, _ := scanner.Get("/fake"); got.Status != "cancelled" {
		t.Fatal(got.Status)
	}
	if cancelCleanup() {
		t.Fatal("nothing to stop")
	}
}

func TestKillableCmdStopsQuickly(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cmd := killableCmd(ctx, "sh", "-c", "sleep 60 & sleep 60; wait")
	done := make(chan struct{})
	go func() { cmd.Output(); close(done) }()
	time.Sleep(200 * time.Millisecond)
	t0 := time.Now()
	cancel()
	select {
	case <-done:
		if time.Since(t0) > 4*time.Second {
			t.Fatalf("took %v", time.Since(t0))
		}
	case <-time.After(6 * time.Second):
		t.Fatal("command did not stop")
	}
}
