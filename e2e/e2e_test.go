// End-to-end: real relay and agent processes, a fake Docker Engine, and a
// member client that signs requests the way the iOS app does.
package e2e

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const adminTok = "admin-token-for-e2e-tests-0123456789"

func build(t *testing.T, dir, out string) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), out)
	cmd := exec.Command("go", "build", "-o", bin, ".")
	cmd.Dir = dir
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build %s: %v\n%s", dir, err, b)
	}
	return bin
}

func freePort(t *testing.T) int {
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func fakeDocker(t *testing.T, sock string) {
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /containers/json", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `[
 {"Id":"aaaaaaaaaaaa1111","Names":["/ERP-Backend"],"Image":"erp-backend:3","State":"running","Status":"Up 2 hours","Labels":{},"Ports":[]},
 {"Id":"bbbbbbbbbbbb2222","Names":["/vaultwarden"],"Image":"vaultwarden/server","State":"running","Status":"Up 2 hours","Labels":{},"Ports":[]},
 {"Id":"cccccccccccc3333","Names":["/n8n"],"Image":"n8nio/n8n","State":"running","Status":"Up 2 hours","Labels":{"com.docker.compose.project":"automation"},"Ports":[]}
]`)
	})
	mux.HandleFunc("GET /containers/{id}/json", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"RestartCount":0,"State":{"StartedAt":"2026-10-31T08:00:00Z"},"HostConfig":{"RestartPolicy":{"Name":"always"}},"Config":{"Tty":true}}`)
	})
	mux.HandleFunc("GET /containers/{id}/stats", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"cpu_stats":{"cpu_usage":{"total_usage":1},"system_cpu_usage":1,"online_cpus":2},"memory_stats":{"usage":1000}}`)
	})
	mux.HandleFunc("POST /containers/{id}/restart", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	mux.HandleFunc("GET /containers/{id}/logs", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/vnd.docker.raw-stream")
		io.WriteString(w, "2026-10-31T09:00:00Z secret=hunter2\n")
	})
	go http.Serve(ln, mux)
}

type client struct {
	t    *testing.T
	base string
}

func (c client) do(method, path, tok string, body any) (int, map[string]any) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, c.base+path, rd)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	b, _ := io.ReadAll(resp.Body)
	_ = json.Unmarshal(b, &out)
	if out == nil {
		out = map[string]any{"_raw": string(b)}
	}
	return resp.StatusCode, out
}

type member struct {
	id, token string
	key       ed25519.PrivateKey
}

// call signs exactly like the app: method\npath\nts\nnonce\nsha256hex(body)
func (c client) call(m member, server, method, path, body string) (int, map[string]any) {
	ts := time.Now().Unix()
	nb := make([]byte, 16)
	rand.Read(nb)
	nonce := base64.RawURLEncoding.EncodeToString(nb)
	sum := sha256.Sum256([]byte(body))
	msg := fmt.Sprintf("%s\n%s\n%d\n%s\n%s", method, path, ts, nonce, hex.EncodeToString(sum[:]))
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(m.key, []byte(msg)))
	return c.do("POST", "/m/v1/servers/"+server+"/call", m.token, map[string]any{
		"method": method, "path": path, "body": body, "ts": ts, "nonce": nonce, "sig": sig})
}

func agentAPI(t *testing.T, agent, cfg string, args ...string) (int, string) {
	out, err := exec.Command(agent, append([]string{"api", "-config", cfg}, args...)...).CombinedOutput()
	if err != nil {
		t.Fatalf("agent api %v: %v %s", args, err, out)
	}
	first, rest, _ := strings.Cut(string(out), "\n")
	var code int
	fmt.Sscanf(first, "HTTP %d", &code)
	return code, rest
}

func TestTeamAccessEndToEnd(t *testing.T) {
	root, _ := filepath.Abs("..")
	relayBin := build(t, filepath.Join(root, "relay"), "relay")
	agentBin := build(t, filepath.Join(root, "agent"), "agent")
	dir := t.TempDir()

	port := freePort(t)
	relay := exec.Command(relayBin)
	relay.Env = append(os.Environ(), fmt.Sprintf("RELAY_ADDR=127.0.0.1:%d", port), "RELAY_DATA="+filepath.Join(dir, "relaydata"), "RELAY_ADMIN_TOKEN="+adminTok)
	relay.Stderr = os.Stderr
	if err := relay.Start(); err != nil {
		t.Fatal(err)
	}
	defer relay.Process.Kill()
	c := client{t: t, base: fmt.Sprintf("http://127.0.0.1:%d", port)}
	for i := 0; i < 50; i++ {
		if resp, err := http.Get(c.base + "/healthz"); err == nil {
			resp.Body.Close()
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	dockerSock := filepath.Join(dir, "docker.sock")
	fakeDocker(t, dockerSock)
	cfg := filepath.Join(dir, "config.json")
	os.WriteFile(cfg, []byte(fmt.Sprintf(`{"name":"romon-prod","socket":%q,"docker_socket":%q,"allow_actions":true}`, filepath.Join(dir, "agent.sock"), dockerSock)), 0o600)
	agent := exec.Command(agentBin, "run", "-config", cfg)
	agent.Stderr = os.Stderr
	if err := agent.Start(); err != nil {
		t.Fatal(err)
	}
	defer agent.Process.Kill()
	time.Sleep(700 * time.Millisecond)

	// unauthenticated admin is rejected
	if code, _ := c.do("GET", "/admin/v1/state", "wrong", nil); code != 401 {
		t.Fatalf("admin auth: %d", code)
	}
	// admin enrolls the server and points the agent at the relay (app does this over SSH)
	code, srv := c.do("POST", "/admin/v1/servers", adminTok, map[string]any{"name": "Romon Prod"})
	if code != 200 {
		t.Fatalf("add server %d %v", code, srv)
	}
	sid := srv["id"].(string)
	body, _ := json.Marshal(map[string]string{"url": c.base, "server_id": sid, "secret": srv["secret"].(string)})
	if code, out := agentAPI(t, agentBin, cfg, "PUT", "/v1/relay", string(body)); code != 200 {
		t.Fatalf("put relay %d %s", code, out)
	}

	// two invites: a viewer limited to erp-*, an operator limited to automation (compose project)
	mk := func(name, role string, pats ...string) member {
		_, inv := c.do("POST", "/admin/v1/invites", adminTok, map[string]any{"name": name, "role": role, "scopes": map[string][]string{sid: pats}})
		pub, priv, _ := ed25519.GenerateKey(rand.Reader)
		code, red := c.do("POST", "/m/v1/redeem", "", map[string]any{"code": inv["code"], "public_key": base64.StdEncoding.EncodeToString(pub), "device": "iPhone"})
		if code != 200 {
			t.Fatalf("redeem %d %v", code, red)
		}
		// single use
		if code, _ := c.do("POST", "/m/v1/redeem", "", map[string]any{"code": inv["code"], "public_key": base64.StdEncoding.EncodeToString(pub)}); code != 400 {
			t.Fatalf("invite reused: %d", code)
		}
		return member{id: red["member_id"].(string), token: red["token"].(string), key: priv}
	}
	ali := mk("Ali", "viewer", "erp-*")
	ayse := mk("Ayse", "operator", "automation")

	// wait for the agent to connect
	for i := 0; i < 50; i++ {
		_, me := c.do("GET", "/m/v1/me", ali.token, nil)
		if srvs, _ := me["servers"].([]any); len(srvs) == 1 && srvs[0].(map[string]any)["online"] == true {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}

	// before the admin syncs members to the agent, requests are refused by the agent itself
	if code, out := c.call(ali, sid, "GET", "/v1/summary", ""); code != 403 || !strings.Contains(fmt.Sprint(out["error"]), "not activated") {
		t.Fatalf("pre-activation: %d %v", code, out)
	}

	// admin app pushes the ACL to the agent over SSH
	_, st := c.do("GET", "/admin/v1/state", adminTok, nil)
	var acl []map[string]any
	for _, m := range st["members"].([]any) {
		mm := m.(map[string]any)
		pats := mm["scopes"].(map[string]any)[sid]
		acl = append(acl, map[string]any{"id": mm["id"], "name": mm["name"], "role": mm["role"], "public_key": mm["public_key"], "scopes": pats})
	}
	ab, _ := json.Marshal(acl)
	if code, out := agentAPI(t, agentBin, cfg, "PUT", "/v1/members", string(ab)); code != 200 {
		t.Fatalf("put members %d %s", code, out)
	}

	names := func(out map[string]any) []string {
		var n []string
		for _, x := range out["snapshot"].(map[string]any)["containers"].([]any) {
			n = append(n, x.(map[string]any)["name"].(string))
		}
		return n
	}
	time.Sleep(300 * time.Millisecond)
	code, out := c.call(ali, sid, "GET", "/v1/summary", "")
	if code != 200 || fmt.Sprint(names(out)) != "[ERP-Backend]" {
		t.Fatalf("viewer scope: %d %v", code, out)
	}
	if svc := out["snapshot"].(map[string]any)["services"].([]any); len(svc) != 0 {
		t.Fatal("services leaked to viewer")
	}
	if code, _ := c.call(ali, sid, "GET", "/v1/containers/vaultwarden", ""); code != 404 {
		t.Fatalf("hidden container visible: %d", code)
	}
	if code, out := c.call(ali, sid, "GET", "/v1/containers/ERP-Backend/logs?tail=10", ""); code != 403 {
		t.Fatalf("viewer logs: %d %v", code, out)
	}
	if code, _ := c.call(ali, sid, "POST", "/v1/containers/ERP-Backend/restart", ""); code != 403 {
		t.Fatalf("viewer restart allowed: %d", code)
	}
	if code, _ := c.call(ali, sid, "GET", "/v1/config", ""); code != 403 {
		t.Fatalf("viewer config: %d", code)
	}

	// operator: compose-project scope, may restart in scope, not out of scope
	code, out = c.call(ayse, sid, "GET", "/v1/summary", "")
	if code != 200 || fmt.Sprint(names(out)) != "[n8n]" {
		t.Fatalf("operator scope: %d %v", code, out)
	}
	if code, out := c.call(ayse, sid, "POST", "/v1/containers/n8n/restart", ""); code != 200 {
		t.Fatalf("operator restart: %d %v", code, out)
	}
	if code, _ := c.call(ayse, sid, "POST", "/v1/containers/ERP-Backend/restart", ""); code != 404 {
		t.Fatalf("operator out of scope: %d", code)
	}

	// a forged request (signed by someone else) is rejected by the agent
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	if code, _ := c.call(member{id: ali.id, token: ali.token, key: other}, sid, "GET", "/v1/summary", ""); code != 403 {
		t.Fatalf("forged signature accepted: %d", code)
	}

	// revoking at the relay cuts access immediately
	c.do("DELETE", "/admin/v1/members/"+ali.id, adminTok, nil)
	if code, _ := c.call(ali, sid, "GET", "/v1/summary", ""); code != 401 {
		t.Fatalf("revoked member: %d", code)
	}
}
