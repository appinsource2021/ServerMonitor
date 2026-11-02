package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Server struct {
	store     *ConfigStore
	collector *Collector
	alerts    *AlertEngine
	apns      *APNs
	docker    *DockerClient
	nonces    nonceCache

	relayMu sync.Mutex
	relay   relayState
}

var containerKeyRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`)
var apnsIDRe = regexp.MustCompile(`^[A-Z0-9]{10}$`)
var deviceTokenRe = regexp.MustCompile(`^[0-9a-fA-F]{32,200}$`)
var bundleIDRe = regexp.MustCompile(`^[A-Za-z0-9.-]{3,155}$`)

func (s *Server) Handler() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /v1/health", s.health)
	m.HandleFunc("GET /v1/summary", s.summary)
	m.HandleFunc("GET /v1/history", s.history)
	m.HandleFunc("GET /v1/containers", s.containers)
	m.HandleFunc("GET /v1/containers/{id}", s.container)
	m.HandleFunc("GET /v1/containers/{id}/logs", s.containerLogs)
	m.HandleFunc("POST /v1/containers/{id}/{action}", s.containerAction)
	m.HandleFunc("GET /v1/services", s.services)
	m.HandleFunc("GET /v1/services/{name}/logs", s.serviceLogs)
	m.HandleFunc("GET /v1/alerts", s.alertsList)
	m.HandleFunc("GET /v1/config", s.config)
	m.HandleFunc("PUT /v1/rules", s.putRules)
	m.HandleFunc("PUT /v1/peers", s.putPeers)
	m.HandleFunc("PUT /v1/settings", s.putSettings)
	m.HandleFunc("PUT /v1/apns", s.putAPNs)
	m.HandleFunc("POST /v1/devices", s.postDevice)
	m.HandleFunc("DELETE /v1/devices/{token}", s.deleteDevice)
	m.HandleFunc("POST /v1/push/test", s.pushTest)
	m.HandleFunc("GET /v1/healthcheck", s.healthCheck)
	m.HandleFunc("POST /v1/disk/scan", s.diskScanStart)
	m.HandleFunc("GET /v1/disk/scan", s.diskScanGet)
	m.HandleFunc("DELETE /v1/disk/scan", s.diskScanCancel)
	m.HandleFunc("GET /v1/disk/docker", s.diskDocker)
	m.HandleFunc("GET /v1/cleanup", s.cleanupScan)
	m.HandleFunc("POST /v1/cleanup", s.cleanupRun)
	m.HandleFunc("DELETE /v1/cleanup", s.cleanupStop)
	m.HandleFunc("GET /v1/members", s.getMembers)
	m.HandleFunc("PUT /v1/members", s.putMembers)
	m.HandleFunc("GET /v1/relay", s.getRelay)
	m.HandleFunc("PUT /v1/relay", s.putRelay)
	m.HandleFunc("GET /v1/fs/list", s.fsList)
	m.HandleFunc("GET /v1/fs/read", s.fsRead)
	m.HandleFunc("PUT /v1/fs/write", s.fsWrite)
	m.HandleFunc("DELETE /v1/fs", s.fsDelete)
	m.HandleFunc("POST /v1/fs/mkdir", s.fsMkdir)
	m.HandleFunc("POST /v1/fs/upload", s.fsUploadSlot)
	m.HandleFunc("POST /v1/fs/import", s.fsImport)
	m.HandleFunc("POST /v1/agent/update", s.agentUpdate)
	return limitBody(m)
}

// TokenAuth guards the optional TCP listener; the unix socket relies on file permissions.
func TokenAuth(store *ConfigStore, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := store.Get().Token
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if tok == "" || subtle.ConstantTimeCompare([]byte(tok), []byte(got)) != 1 {
			writeErr(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func limitBody(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		limit := int64(64 << 10)
		if r.URL.Path == "/v1/fs/write" { // file content travels in the body
			limit = fsMaxBody
		}
		r.Body = http.MaxBytesReader(w, r.Body, limit)
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func readJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	if dec.More() {
		return errors.New("trailing data")
	}
	return nil
}

func intParam(r *http.Request, name string, def, min, max int) int {
	v, err := strconv.Atoi(r.URL.Query().Get(name))
	if err != nil {
		return def
	}
	if v < min {
		return min
	}
	if v > max {
		return max
	}
	return v
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	cfg := s.store.Get()
	writeJSON(w, 200, map[string]any{"ok": true, "name": cfg.Name, "version": version, "time": time.Now()})
}

type Status struct {
	Level    string `json:"level"` // healthy, warning, critical
	Critical int    `json:"critical"`
	Warning  int    `json:"warning"`
}

func statusFrom(alerts []Alert) Status {
	st := Status{Level: "healthy"}
	for _, a := range alerts {
		if a.Severity == "critical" {
			st.Critical++
		} else {
			st.Warning++
		}
	}
	if st.Critical > 0 {
		st.Level = "critical"
	} else if st.Warning > 0 {
		st.Level = "warning"
	}
	return st
}

type ContainerCounts struct {
	Total    int `json:"total"`
	Running  int `json:"running"`
	Problems int `json:"problems"`
}

func (s *Server) summary(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, s.summaryFor(nil, func(Container) bool { return true }))
}

func (s *Server) history(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, s.collector.History())
}

func (s *Server) containers(w http.ResponseWriter, r *http.Request) {
	snap := s.collector.Snapshot()
	writeJSON(w, 200, map[string]any{"available": snap.DockerAvailable, "error": snap.DockerError, "containers": snap.Containers})
}

func (s *Server) container(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	c, ok := s.collector.FindContainer(id)
	if !ok {
		writeErr(w, 404, "container not found")
		return
	}
	writeJSON(w, 200, c)
}

func (s *Server) containerLogs(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !containerKeyRe.MatchString(id) {
		writeErr(w, 400, "invalid container id")
		return
	}
	c, ok := s.collector.FindContainer(id)
	if !ok {
		writeErr(w, 404, "container not found")
		return
	}
	tail := intParam(r, "tail", 200, 1, 5000)
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	lines, err := s.docker.Logs(r.Context(), c.ID, tail, since, c.tty)
	if err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	if lines == nil {
		lines = []LogLine{}
	}
	writeJSON(w, 200, map[string]any{"container": c.Name, "lines": lines})
}

func (s *Server) containerAction(w http.ResponseWriter, r *http.Request) {
	if !s.store.Get().AllowActions {
		writeErr(w, 403, "container actions are disabled on this server (allow_actions=false)")
		return
	}
	id, action := r.PathValue("id"), r.PathValue("action")
	if !containerKeyRe.MatchString(id) {
		writeErr(w, 400, "invalid container id")
		return
	}
	c, ok := s.collector.FindContainer(id)
	if !ok {
		writeErr(w, 404, "container not found")
		return
	}
	t0 := time.Now()
	if err := s.docker.Action(r.Context(), c.ID, action); err != nil {
		var de *DockerAPIError
		if errors.As(err, &de) {
			writeErr(w, de.Status, de.Message)
			return
		}
		writeErr(w, 400, err.Error())
		return
	}
	// Docker's start/stop/restart calls return once the change is done:
	// refresh now so the app sees the new state without waiting for the next tick.
	s.collector.collectDocker(r.Context())
	resp := map[string]any{"ok": true, "container": c.Name, "action": action, "took_ms": time.Since(t0).Milliseconds()}
	if updated, ok := s.collector.FindContainer(c.Name); ok {
		resp["state"] = updated
	}
	writeJSON(w, 200, resp)
}

func (s *Server) services(w http.ResponseWriter, r *http.Request) {
	snap := s.collector.Snapshot()
	writeJSON(w, 200, map[string]any{"available": snap.SystemdAvailable, "services": snap.Services})
}

func (s *Server) serviceLogs(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !unitNameRe.MatchString(name) {
		writeErr(w, 400, "invalid unit name")
		return
	}
	lines, err := serviceLogs(r.Context(), name, intParam(r, "tail", 200, 1, 5000))
	if err != nil {
		writeErr(w, 502, err.Error())
		return
	}
	if lines == nil {
		lines = []LogLine{}
	}
	writeJSON(w, 200, map[string]any{"service": name, "lines": lines})
}

func (s *Server) alertsList(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"active": s.alerts.Active(), "history": s.alerts.History()})
}

// config never returns secrets (token, key contents).
func (s *Server) config(w http.ResponseWriter, r *http.Request) {
	c := s.store.Get()
	devices := make([]map[string]string, 0, len(c.Devices))
	for _, d := range c.Devices {
		devices = append(devices, map[string]string{"token": shortToken(d.Token), "env": d.Env, "name": d.Name})
	}
	writeJSON(w, 200, map[string]any{
		"name":          c.Name,
		"allow_actions": c.AllowActions,
		"disks":         c.Disks,
		"rules":         c.Rules,
		"peers":         c.Peers,
		"devices":       devices,
		"apns": map[string]any{
			"configured": c.APNs.Configured(),
			"key_id":     c.APNs.KeyID,
			"team_id":    c.APNs.TeamID,
			"bundle_id":  c.APNs.BundleID,
		},
	})
}

func (s *Server) putRules(w http.ResponseWriter, r *http.Request) {
	var rules Rules
	if err := readJSON(r, &rules); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	for _, p := range []float64{rules.CPU.Percent, rules.Memory.Percent, rules.Disk.Percent} {
		if p < 1 || p > 100 {
			writeErr(w, 400, "percent thresholds must be between 1 and 100")
			return
		}
	}
	c, err := s.store.Update(func(c *Config) error { c.Rules = rules; return nil })
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, c.Rules)
}

func (s *Server) putPeers(w http.ResponseWriter, r *http.Request) {
	var peers []Peer
	if err := readJSON(r, &peers); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	for _, p := range peers {
		if p.Name == "" || p.Host == "" || p.Port < 0 || p.Port > 65535 {
			writeErr(w, 400, "each peer needs name, host and a valid port")
			return
		}
	}
	c, err := s.store.Update(func(c *Config) error { c.Peers = peers; return nil })
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, c.Peers)
}

func (s *Server) putSettings(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Name         *string   `json:"name"`
		AllowActions *bool     `json:"allow_actions"`
		Disks        *[]string `json:"disks"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	c, err := s.store.Update(func(c *Config) error {
		if in.Name != nil {
			n := strings.TrimSpace(*in.Name)
			if n == "" || len(n) > 64 {
				return errors.New("name must be 1-64 characters")
			}
			c.Name = n
		}
		if in.AllowActions != nil {
			c.AllowActions = *in.AllowActions
		}
		if in.Disks != nil {
			for _, d := range *in.Disks {
				if !filepath.IsAbs(d) {
					return errors.New("disks must be absolute mount paths")
				}
			}
			c.Disks = *in.Disks
		}
		return nil
	})
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"name": c.Name, "allow_actions": c.AllowActions, "disks": c.Disks})
}

func (s *Server) putAPNs(w http.ResponseWriter, r *http.Request) {
	var in struct {
		KeyID    string `json:"key_id"`
		TeamID   string `json:"team_id"`
		BundleID string `json:"bundle_id"`
		KeyP8    string `json:"key_p8"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if !apnsIDRe.MatchString(in.KeyID) || !apnsIDRe.MatchString(in.TeamID) || !bundleIDRe.MatchString(in.BundleID) {
		writeErr(w, 400, "key_id and team_id are 10 characters (A-Z, 0-9); bundle_id is required")
		return
	}
	if _, err := parseP8([]byte(in.KeyP8)); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	cfg := s.store.Get()
	keyPath := cfg.APNs.KeyPath
	if keyPath == "" {
		keyPath = filepath.Join(filepath.Dir(configPath), "apns.p8")
	}
	if err := writeFileAtomic(keyPath, []byte(in.KeyP8), 0o600); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	_, err := s.store.Update(func(c *Config) error {
		c.APNs = APNsConfig{KeyPath: keyPath, KeyID: in.KeyID, TeamID: in.TeamID, BundleID: in.BundleID}
		return nil
	})
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "key_id": in.KeyID})
}

func (s *Server) postDevice(w http.ResponseWriter, r *http.Request) {
	var d Device
	if err := readJSON(r, &d); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if !deviceTokenRe.MatchString(d.Token) {
		writeErr(w, 400, "invalid device token")
		return
	}
	d.Token = strings.ToLower(d.Token)
	_, err := s.store.Update(func(c *Config) error {
		for i := range c.Devices {
			if c.Devices[i].Token == d.Token {
				c.Devices[i] = d
				return nil
			}
		}
		if len(c.Devices) >= 20 {
			return errors.New("too many devices")
		}
		c.Devices = append(c.Devices, d)
		return nil
	})
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (s *Server) deleteDevice(w http.ResponseWriter, r *http.Request) {
	tok := strings.ToLower(r.PathValue("token"))
	removed := false
	_, err := s.store.Update(func(c *Config) error {
		keep := c.Devices[:0]
		for _, d := range c.Devices {
			if d.Token == tok {
				removed = true
				continue
			}
			keep = append(keep, d)
		}
		c.Devices = keep
		return nil
	})
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "removed": removed})
}

func (s *Server) pushTest(w http.ResponseWriter, r *http.Request) {
	cfg := s.store.Get()
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	res, err := s.apns.Send(ctx, Notification{Server: cfg.Name, Key: "test", Severity: "info",
		Title: "Test notification", Body: "Push alerts from " + cfg.Name + " are working."})
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"results": res})
}

func writeFileAtomic(path string, b []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := io.Copy(tmp, strings.NewReader(string(b))); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// ---- team (admin only: reachable over SSH, never through the relay) ----

func (s *Server) getMembers(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, s.store.Get().Members)
}

func (s *Server) putMembers(w http.ResponseWriter, r *http.Request) {
	var ms []Member
	if err := readJSON(r, &ms); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if err := validateMembers(ms); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	ids := map[string]bool{}
	for _, m := range ms {
		ids[m.ID] = true
	}
	c, err := s.store.Update(func(c *Config) error {
		c.Members = ms
		// a removed member's phones stop getting pushes too
		keep := c.Devices[:0]
		for _, d := range c.Devices {
			if d.MemberID == "" || ids[d.MemberID] {
				keep = append(keep, d)
			}
		}
		c.Devices = keep
		return nil
	})
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "members": len(c.Members)})
}

func (s *Server) getRelay(w http.ResponseWriter, r *http.Request) {
	rc := s.store.Get().Relay
	s.relayMu.Lock()
	st := s.relay
	s.relayMu.Unlock()
	writeJSON(w, 200, map[string]any{"configured": rc.Configured(), "url": rc.URL, "server_id": rc.ServerID,
		"connected": st.Connected, "error": st.Error, "since": st.Since})
}

func (s *Server) putRelay(w http.ResponseWriter, r *http.Request) {
	var rc RelayConfig
	if err := readJSON(r, &rc); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if rc.URL != "" && !strings.HasPrefix(rc.URL, "https://") && !strings.HasPrefix(rc.URL, "http://127.0.0.1") && !strings.HasPrefix(rc.URL, "http://localhost") {
		writeErr(w, 400, "relay url must be https")
		return
	}
	if _, err := s.store.Update(func(c *Config) error { c.Relay = rc; return nil }); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}
