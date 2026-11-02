package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"path"
	"regexp"
	"strings"
	"sync"
	"time"
)

var roleRank = map[string]int{"viewer": 1, "operator": 2, "admin": 3}

// inScope: case-insensitive glob ("erp-*", "*db*", "n8n") against a container's
// name, image and compose project/service. No patterns means nothing is visible.
func inScope(patterns []string, c Container) bool {
	fields := []string{c.Name, c.Image, c.ComposeProject, c.ComposeService}
	for _, p := range patterns {
		p = strings.ToLower(strings.TrimSpace(p))
		if p == "" {
			continue
		}
		if p == "*" {
			return true
		}
		for _, f := range fields {
			if f == "" {
				continue
			}
			if ok, _ := path.Match(p, strings.ToLower(f)); ok {
				return true
			}
		}
	}
	return false
}

// memberSees decides whether an alert may reach a member: host-level
// alerts (CPU, memory, disk) and alerts about containers in scope only.
func memberSees(m Member, a Alert, containers []Container) bool {
	if a.Service != "" || strings.HasPrefix(a.Key, "peer_down:") {
		return m.Role == "admin"
	}
	if a.Container == "" {
		return true
	}
	if m.Role == "admin" {
		return true
	}
	for _, c := range containers {
		if c.Name == a.Container {
			return inScope(m.Scopes, c)
		}
	}
	return inScope(m.Scopes, Container{Name: a.Container})
}

func validateMembers(ms []Member) error {
	seen := map[string]bool{}
	for _, m := range ms {
		if m.ID == "" || seen[m.ID] {
			return fmt.Errorf("member id missing or duplicate: %q", m.ID)
		}
		seen[m.ID] = true
		if roleRank[m.Role] == 0 {
			return fmt.Errorf("member %s: role must be admin, operator or viewer", m.ID)
		}
		pk, err := base64.StdEncoding.DecodeString(m.PublicKey)
		if err != nil || len(pk) != ed25519.PublicKeySize {
			return fmt.Errorf("member %s: bad public key", m.ID)
		}
		for _, p := range m.Scopes {
			if _, err := path.Match(strings.ToLower(p), ""); err != nil {
				return fmt.Errorf("member %s: bad pattern %q", m.ID, p)
			}
		}
	}
	return nil
}

// ---- signatures ----

// signingString must match the app: method, path, ts, nonce, sha256(body) hex.
func signingString(method, p string, ts int64, nonce, body string) []byte {
	sum := sha256.Sum256([]byte(body))
	return []byte(fmt.Sprintf("%s\n%s\n%d\n%s\n%s", method, p, ts, nonce, hex.EncodeToString(sum[:])))
}

type nonceCache struct {
	mu   sync.Mutex
	seen map[string]time.Time
}

func (n *nonceCache) Use(key string) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	now := time.Now()
	if len(n.seen) > 5000 {
		for k, t := range n.seen {
			if now.Sub(t) > 10*time.Minute {
				delete(n.seen, k)
			}
		}
	}
	if _, dup := n.seen[key]; dup {
		return false
	}
	n.seen[key] = now
	return true
}

type RelayRequest struct {
	ID       string `json:"id"`
	MemberID string `json:"member_id"`
	Method   string `json:"method"`
	Path     string `json:"path"`
	Body     string `json:"body,omitempty"`
	TS       int64  `json:"ts"`
	Nonce    string `json:"nonce"`
	Sig      string `json:"sig"`
}

type RelayReply struct {
	ID     string `json:"id"`
	Status int    `json:"status"`
	Body   string `json:"body"`
}

var nonceRe = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)

// verify checks the member exists here and that the request was signed by
// that member's device, recently and only once. The relay is not trusted.
func (s *Server) verify(req RelayRequest) (Member, error) {
	var m Member
	found := false
	for _, x := range s.store.Get().Members {
		if x.ID == req.MemberID {
			m, found = x, true
			break
		}
	}
	if !found {
		return m, errors.New("not activated on this server yet — ask the admin to open the app")
	}
	if d := time.Since(time.Unix(req.TS, 0)); d > 2*time.Minute || d < -2*time.Minute {
		return m, errors.New("request expired: check the phone's clock")
	}
	if !nonceRe.MatchString(req.Nonce) {
		return m, errors.New("bad nonce")
	}
	pk, _ := base64.StdEncoding.DecodeString(m.PublicKey)
	sig, err := base64.StdEncoding.DecodeString(req.Sig)
	if err != nil || len(pk) != ed25519.PublicKeySize ||
		!ed25519.Verify(ed25519.PublicKey(pk), signingString(req.Method, req.Path, req.TS, req.Nonce, req.Body), sig) {
		return m, errors.New("bad signature")
	}
	if !s.nonces.Use(m.ID + ":" + req.Nonce) {
		return m, errors.New("replayed request")
	}
	return m, nil
}

// ---- member API ----

var (
	reContainer       = regexp.MustCompile(`^/v1/containers/([A-Za-z0-9][A-Za-z0-9_.-]{0,127})$`)
	reContainerLogs   = regexp.MustCompile(`^/v1/containers/([A-Za-z0-9][A-Za-z0-9_.-]{0,127})/logs$`)
	reContainerAction = regexp.MustCompile(`^/v1/containers/([A-Za-z0-9][A-Za-z0-9_.-]{0,127})/(start|stop|restart)$`)
	reServiceLogs     = regexp.MustCompile(`^/v1/services/[^/]+/logs$`)
	reDevice          = regexp.MustCompile(`^/v1/devices/[0-9a-fA-F]{32,200}$`)
)

// HandleMember answers one relay request with the member's view of the server.
func (s *Server) HandleMember(ctx context.Context, req RelayRequest) RelayReply {
	rep := func(code int, v any) RelayReply {
		b, _ := json.Marshal(v)
		return RelayReply{ID: req.ID, Status: code, Body: string(b)}
	}
	deny := func(code int, msg string) RelayReply { return rep(code, map[string]string{"error": msg}) }

	m, err := s.verify(req)
	if err != nil {
		return deny(403, err.Error())
	}
	pathOnly, query, _ := strings.Cut(req.Path, "?")
	admin := m.Role == "admin"
	visible := func(c Container) bool { return admin || inScope(m.Scopes, c) }

	switch {
	case req.Method == "GET" && pathOnly == "/v1/health":
		return rep(200, map[string]any{"ok": true, "name": s.store.Get().Name, "version": version, "role": m.Role})

	case req.Method == "GET" && pathOnly == "/v1/summary":
		return rep(200, s.summaryFor(&m, visible))

	case req.Method == "GET" && pathOnly == "/v1/history":
		return rep(200, s.collector.History())

	case req.Method == "GET" && pathOnly == "/v1/containers":
		snap := s.collector.Snapshot()
		out := []Container{}
		for _, c := range snap.Containers {
			if visible(c) {
				out = append(out, c)
			}
		}
		return rep(200, map[string]any{"available": snap.DockerAvailable, "containers": out})

	case req.Method == "GET" && reContainer.MatchString(pathOnly):
		c, ok := s.collector.FindContainer(reContainer.FindStringSubmatch(pathOnly)[1])
		if !ok || !visible(c) {
			return deny(404, "container not found")
		}
		return rep(200, c)

	case req.Method == "GET" && reContainerLogs.MatchString(pathOnly):
		if !admin {
			return deny(403, "logs are visible to admins only")
		}
		return s.forward(ctx, req)

	case req.Method == "POST" && reContainerAction.MatchString(pathOnly):
		if roleRank[m.Role] < roleRank["operator"] {
			return deny(403, "your role can only view containers")
		}
		c, ok := s.collector.FindContainer(reContainerAction.FindStringSubmatch(pathOnly)[1])
		if !ok || !visible(c) {
			return deny(404, "container not found")
		}
		log.Printf("member %s (%s) %s", m.Name, m.Role, req.Path)
		return s.forward(ctx, req)

	case req.Method == "GET" && (pathOnly == "/v1/services" || reServiceLogs.MatchString(pathOnly) || pathOnly == "/v1/alerts"):
		if pathOnly == "/v1/alerts" {
			snap := s.collector.Snapshot()
			act := []Alert{}
			for _, a := range s.alerts.Active() {
				if memberSees(m, a, snap.Containers) {
					act = append(act, a)
				}
			}
			return rep(200, map[string]any{"active": act, "history": []Alert{}})
		}
		if !admin {
			return deny(403, "system services are visible to admins only")
		}
		return s.forward(ctx, req)

	case req.Method == "POST" && pathOnly == "/v1/devices":
		var d Device
		if err := json.Unmarshal([]byte(req.Body), &d); err != nil || !deviceTokenRe.MatchString(d.Token) {
			return deny(400, "invalid device")
		}
		if d.Env != "development" && d.Env != "production" {
			return deny(400, "invalid env")
		}
		d.Token, d.MemberID = strings.ToLower(d.Token), m.ID
		_, err := s.store.Update(func(c *Config) error {
			for i := range c.Devices {
				if c.Devices[i].Token == d.Token {
					c.Devices[i] = d
					return nil
				}
			}
			c.Devices = append(c.Devices, d)
			return nil
		})
		if err != nil {
			return deny(400, err.Error())
		}
		return rep(200, map[string]any{"ok": true})

	case req.Method == "DELETE" && reDevice.MatchString(pathOnly):
		tok := strings.ToLower(strings.TrimPrefix(pathOnly, "/v1/devices/"))
		_, _ = s.store.Update(func(c *Config) error {
			keep := c.Devices[:0]
			for _, d := range c.Devices {
				if !(d.Token == tok && d.MemberID == m.ID) {
					keep = append(keep, d)
				}
			}
			c.Devices = keep
			return nil
		})
		return rep(200, map[string]any{"ok": true})
	}
	_ = query
	return deny(403, "not allowed for team members")
}

// forward runs an already-authorized request through the normal API handler.
func (s *Server) forward(ctx context.Context, req RelayRequest) RelayReply {
	var body io.Reader
	if req.Body != "" {
		body = strings.NewReader(req.Body)
	}
	hr := httptest.NewRequest(req.Method, req.Path, body).WithContext(ctx)
	if req.Body != "" {
		hr.Header.Set("Content-Type", "application/json")
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, hr)
	return RelayReply{ID: req.ID, Status: rec.Code, Body: rec.Body.String()}
}

// summaryFor is /v1/summary restricted to what this member may see.
// m == nil means the full admin view.
func (s *Server) summaryFor(m *Member, visible func(Container) bool) map[string]any {
	snap := s.collector.Snapshot()
	active := s.alerts.Active()
	admin := m == nil || m.Role == "admin"
	if !admin {
		cs := []Container{}
		for _, c := range snap.Containers {
			if visible(c) {
				cs = append(cs, c)
			}
		}
		filtered := []Alert{}
		for _, a := range active {
			if memberSees(*m, a, snap.Containers) {
				filtered = append(filtered, a)
			}
		}
		snap.Containers = cs
		snap.Services = []Service{}
		snap.SystemdAvailable = false
		snap.Peers = []PeerStatus{}
		snap.Docker = nil
		active = filtered
	}
	history := s.collector.History()
	if !admin {
		for i := range history {
			history[i].DockerCPU, history[i].DockerMem = 0, 0
		}
	}
	cc := ContainerCounts{Total: len(snap.Containers)}
	for _, c := range snap.Containers {
		if c.State == "running" {
			cc.Running++
		}
		if stateRank(c) <= 1 && !c.Ignored {
			cc.Problems++
		}
	}
	failed := 0
	for _, sv := range snap.Services {
		if sv.Active == "failed" {
			failed++
		}
	}
	out := map[string]any{
		"snapshot":        snap,
		"status":          statusFrom(active),
		"alerts":          active,
		"container_count": cc,
		"failed_services": failed,
		"history":         history,
	}
	if m != nil {
		out["viewer"] = map[string]string{"id": m.ID, "name": m.Name, "role": m.Role}
	}
	return out
}

// ---- outbound relay connection ----

// RunRelay keeps a long-poll open to the relay and answers member requests.
// It restarts itself when the relay settings change.
func (s *Server) RunRelay(ctx context.Context) {
	client := &http.Client{Timeout: 40 * time.Second}
	backoff := time.Second
	for ctx.Err() == nil {
		rc := s.store.Get().Relay
		if !rc.Configured() {
			select {
			case <-ctx.Done():
				return
			case <-time.After(10 * time.Second):
			}
			continue
		}
		base := strings.TrimRight(rc.URL, "/")
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+"/agent/v1/poll", nil)
		req.Header.Set("Authorization", "Bearer "+rc.Secret)
		req.Header.Set("X-Server-Id", rc.ServerID)
		req.Header.Set("User-Agent", "srvmon-agent/"+version)
		resp, err := client.Do(req)
		if err != nil || (resp.StatusCode != 200 && resp.StatusCode != 204) {
			msg := ""
			if err != nil {
				msg = err.Error()
			} else {
				b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
				resp.Body.Close()
				msg = fmt.Sprintf("HTTP %d %s", resp.StatusCode, strings.TrimSpace(string(b)))
			}
			s.setRelayState(false, msg)
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			if backoff < time.Minute {
				backoff *= 2
			}
			continue
		}
		backoff = time.Second
		s.setRelayState(true, "")
		if resp.StatusCode == 204 {
			resp.Body.Close()
			continue
		}
		var reqs []RelayRequest
		err = json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(&reqs)
		resp.Body.Close()
		if err != nil {
			continue
		}
		for _, rr := range reqs {
			go s.answer(ctx, client, base, rc, rr)
		}
	}
}

func (s *Server) answer(ctx context.Context, client *http.Client, base string, rc RelayConfig, rr RelayRequest) {
	cctx, cancel := context.WithTimeout(ctx, 40*time.Second)
	defer cancel()
	rep := s.HandleMember(cctx, rr)
	b, _ := json.Marshal([]RelayReply{rep})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, base+"/agent/v1/reply", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+rc.Secret)
	req.Header.Set("X-Server-Id", rc.ServerID)
	req.Header.Set("Content-Type", "application/json")
	if resp, err := client.Do(req); err == nil {
		resp.Body.Close()
	}
}

type relayState struct {
	Connected bool      `json:"connected"`
	Error     string    `json:"error,omitempty"`
	Since     time.Time `json:"since"`
}

func (s *Server) setRelayState(ok bool, msg string) {
	s.relayMu.Lock()
	defer s.relayMu.Unlock()
	if s.relay.Connected != ok || s.relay.Error != msg {
		if ok {
			log.Printf("relay connected")
		} else {
			log.Printf("relay: %s", msg)
		}
		s.relay = relayState{Connected: ok, Error: msg, Since: time.Now()}
	}
}

// deviceMaySee: admin phones get everything, member phones only what their scope allows.
func (s *Server) deviceMaySee(d Device, n Notification) bool {
	if d.MemberID == "" {
		return true
	}
	for _, m := range s.store.Get().Members {
		if m.ID == d.MemberID {
			a := Alert{Key: n.Key, Container: n.Container}
			if strings.HasPrefix(n.Key, "systemd:") {
				a.Service = n.Key
			}
			return memberSees(m, a, s.collector.Snapshot().Containers)
		}
	}
	return false
}
