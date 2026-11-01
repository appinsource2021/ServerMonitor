package main

import (
	"context"
	"crypto/ed25519"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	pollWait     = 25 * time.Second
	callTimeout  = 45 * time.Second
	offlineAfter = 60 * time.Second
	inviteTTL    = 48 * time.Hour
)

var roleOK = map[string]bool{"admin": true, "operator": true, "viewer": true}
var idRe = regexp.MustCompile(`^[a-f0-9]{16}$`)

// Request is one app call waiting for an agent.
type Request struct {
	ID       string `json:"id"`
	MemberID string `json:"member_id"`
	Method   string `json:"method"`
	Path     string `json:"path"`
	Body     string `json:"body,omitempty"`
	TS       int64  `json:"ts"`
	Nonce    string `json:"nonce"`
	Sig      string `json:"sig"`
}

type Reply struct {
	ID     string `json:"id"`
	Status int    `json:"status"`
	Body   string `json:"body"`
}

type serverQueue struct {
	ch       chan *Request
	lastPoll time.Time
}

// Hub routes requests from member apps to agents and replies back.
type Hub struct {
	mu      sync.Mutex
	queues  map[string]*serverQueue
	waiting map[string]chan Reply // request id -> reply
	owner   map[string]string     // request id -> server id
}

func NewHub() *Hub {
	return &Hub{queues: map[string]*serverQueue{}, waiting: map[string]chan Reply{}, owner: map[string]string{}}
}

func (h *Hub) queue(serverID string) *serverQueue {
	q, ok := h.queues[serverID]
	if !ok {
		q = &serverQueue{ch: make(chan *Request, 64)}
		h.queues[serverID] = q
	}
	return q
}

func (h *Hub) touch(serverID string) {
	h.mu.Lock()
	h.queue(serverID).lastPoll = time.Now()
	h.mu.Unlock()
}

func (h *Hub) Online(serverID string) (bool, time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	q, ok := h.queues[serverID]
	if !ok {
		return false, time.Time{}
	}
	return time.Since(q.lastPoll) < offlineAfter, q.lastPoll
}

var errOffline = errors.New("server is offline (its agent is not connected to the relay)")

func (h *Hub) Call(ctx context.Context, serverID string, r *Request) (Reply, error) {
	if ok, _ := h.Online(serverID); !ok {
		return Reply{}, errOffline
	}
	r.ID = randomID()
	ch := make(chan Reply, 1)
	h.mu.Lock()
	q := h.queue(serverID)
	h.waiting[r.ID] = ch
	h.owner[r.ID] = serverID
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		delete(h.waiting, r.ID)
		delete(h.owner, r.ID)
		h.mu.Unlock()
	}()
	select {
	case q.ch <- r:
	default:
		return Reply{}, errors.New("server queue full")
	}
	ctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	select {
	case rep := <-ch:
		return rep, nil
	case <-ctx.Done():
		return Reply{}, errors.New("server did not answer in time")
	}
}

// Poll waits for work for one agent.
func (h *Hub) Poll(ctx context.Context, serverID string) []*Request {
	h.touch(serverID)
	defer h.touch(serverID)
	h.mu.Lock()
	q := h.queue(serverID)
	h.mu.Unlock()
	t := time.NewTimer(pollWait)
	defer t.Stop()
	var out []*Request
	select {
	case r := <-q.ch:
		out = append(out, r)
	case <-t.C:
		return nil
	case <-ctx.Done():
		return nil
	}
	for len(out) < 16 {
		select {
		case r := <-q.ch:
			out = append(out, r)
		default:
			return out
		}
	}
	return out
}

func (h *Hub) Deliver(serverID string, rep Reply) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.owner[rep.ID] != serverID {
		return false // only the agent that got the request may answer it
	}
	ch, ok := h.waiting[rep.ID]
	if ok {
		ch <- rep
	}
	return ok
}

// ---- HTTP ----

type Relay struct {
	store      *Store
	hub        *Hub
	adminToken string
	limiter    *limiter
}

func (rl *Relay) Handler() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]any{"ok": true}) })

	m.HandleFunc("GET /admin/v1/state", rl.admin(rl.adminState))
	m.HandleFunc("POST /admin/v1/servers", rl.admin(rl.adminAddServer))
	m.HandleFunc("DELETE /admin/v1/servers/{id}", rl.admin(rl.adminDeleteServer))
	m.HandleFunc("POST /admin/v1/invites", rl.admin(rl.adminInvite))
	m.HandleFunc("DELETE /admin/v1/invites/{id}", rl.admin(rl.adminDeleteInvite))
	m.HandleFunc("PUT /admin/v1/members/{id}", rl.admin(rl.adminUpdateMember))
	m.HandleFunc("DELETE /admin/v1/members/{id}", rl.admin(rl.adminDeleteMember))
	m.HandleFunc("POST /admin/v1/members/{id}/synced", rl.admin(rl.adminSynced))

	m.HandleFunc("POST /m/v1/redeem", rl.redeem)
	m.HandleFunc("GET /m/v1/me", rl.member(rl.me))
	m.HandleFunc("POST /m/v1/servers/{id}/call", rl.member(rl.call))

	m.HandleFunc("GET /agent/v1/poll", rl.agent(rl.poll))
	m.HandleFunc("POST /agent/v1/reply", rl.agent(rl.reply))
	return limitBody(m)
}

func limitBody(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 8<<20)
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func bearer(r *http.Request) string {
	return strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
}

func readJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

func clientIP(r *http.Request) string {
	if f := r.Header.Get("X-Forwarded-For"); f != "" {
		return strings.TrimSpace(strings.Split(f, ",")[0])
	}
	h, _, _ := net.SplitHostPort(r.RemoteAddr)
	return h
}

func (rl *Relay) admin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !rl.limiter.Allow("admin:" + clientIP(r)) {
			writeErr(w, 429, "too many requests")
			return
		}
		if subtle.ConstantTimeCompare([]byte(bearer(r)), []byte(rl.adminToken)) != 1 {
			rl.limiter.Fail("admin:" + clientIP(r))
			writeErr(w, 401, "unauthorized")
			return
		}
		next(w, r)
	}
}

type ctxKey string

func (rl *Relay) member(next func(http.ResponseWriter, *http.Request, *Member)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok := bearer(r)
		if tok == "" {
			writeErr(w, 401, "unauthorized")
			return
		}
		h := hashSecret(tok)
		var mem Member
		found := false
		_ = rl.store.With(func(st *state) (bool, error) {
			for _, m := range st.Members {
				if m.TokenHash != "" && subtle.ConstantTimeCompare([]byte(m.TokenHash), []byte(h)) == 1 {
					now := time.Now()
					changed := m.LastSeen == nil || now.Sub(*m.LastSeen) > time.Minute
					if changed {
						m.LastSeen = &now
					}
					mem = *m
					found = true
					return changed, nil
				}
			}
			return false, nil
		})
		if !found {
			writeErr(w, 401, "access revoked or unknown device")
			return
		}
		next(w, r, &mem)
	}
}

func (rl *Relay) agent(next func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Server-Id")
		var ok bool
		_ = rl.store.With(func(st *state) (bool, error) {
			s, found := st.Servers[id]
			ok = found && subtle.ConstantTimeCompare([]byte(s.SecretHash), []byte(hashSecret(bearer(r)))) == 1
			return false, nil
		})
		if !ok {
			writeErr(w, 401, "unknown server")
			return
		}
		next(w, r, id)
	}
}

// ---- admin ----

type serverView struct {
	ID       string     `json:"id"`
	Name     string     `json:"name"`
	Online   bool       `json:"online"`
	LastSeen *time.Time `json:"last_seen,omitempty"`
}

type memberView struct {
	ID         string              `json:"id"`
	Name       string              `json:"name"`
	Role       string              `json:"role"`
	Scopes     map[string][]string `json:"scopes"`
	PublicKey  string              `json:"public_key,omitempty"`
	Device     string              `json:"device,omitempty"`
	Joined     bool                `json:"joined"`
	JoinedAt   *time.Time          `json:"joined_at,omitempty"`
	LastSeen   *time.Time          `json:"last_seen,omitempty"`
	ACLVersion int                 `json:"acl_version"`
	Synced     int                 `json:"synced_version"`
	InviteID   string              `json:"invite_id,omitempty"`
	InviteExp  *time.Time          `json:"invite_expires_at,omitempty"`
}

func (rl *Relay) adminState(w http.ResponseWriter, r *http.Request) {
	var servers []serverView
	var members []memberView
	_ = rl.store.With(func(st *state) (bool, error) {
		changed := false
		for id, inv := range st.Invites {
			if time.Now().After(inv.ExpiresAt) {
				if m, ok := st.Members[inv.MemberID]; ok && m.JoinedAt == nil {
					delete(st.Members, inv.MemberID)
				}
				delete(st.Invites, id)
				changed = true
			}
		}
		for _, s := range st.Servers {
			on, last := rl.hub.Online(s.ID)
			v := serverView{ID: s.ID, Name: s.Name, Online: on}
			if !last.IsZero() {
				v.LastSeen = &last
			}
			servers = append(servers, v)
		}
		pending := map[string]*Invite{}
		for _, inv := range st.Invites {
			pending[inv.MemberID] = inv
		}
		for _, m := range st.Members {
			v := memberView{ID: m.ID, Name: m.Name, Role: m.Role, Scopes: m.Scopes, PublicKey: m.PublicKey, Device: m.Device,
				Joined: m.JoinedAt != nil, JoinedAt: m.JoinedAt, LastSeen: m.LastSeen, ACLVersion: m.ACLVersion, Synced: m.Synced}
			if inv, ok := pending[m.ID]; ok && m.JoinedAt == nil {
				v.InviteID = inv.ID
				exp := inv.ExpiresAt
				v.InviteExp = &exp
			}
			members = append(members, v)
		}
		return changed, nil
	})
	sort.Slice(servers, func(i, j int) bool { return servers[i].Name < servers[j].Name })
	sort.Slice(members, func(i, j int) bool { return members[i].Name < members[j].Name })
	if servers == nil {
		servers = []serverView{}
	}
	if members == nil {
		members = []memberView{}
	}
	writeJSON(w, 200, map[string]any{"servers": servers, "members": members})
}

func (rl *Relay) adminAddServer(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" || len(in.Name) > 64 {
		writeErr(w, 400, "name is required (max 64)")
		return
	}
	if in.ID != "" && !idRe.MatchString(in.ID) {
		writeErr(w, 400, "bad id")
		return
	}
	secret := randomToken(32)
	var out Server
	err := rl.store.With(func(st *state) (bool, error) {
		id := in.ID
		if id == "" {
			id = randomID()
		}
		s, ok := st.Servers[id]
		if !ok {
			s = &Server{ID: id, CreatedAt: time.Now()}
			st.Servers[id] = s
		}
		s.Name = in.Name
		s.SecretHash = hashSecret(secret) // re-issuing rotates the secret
		out = *s
		return true, nil
	})
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"id": out.ID, "name": out.Name, "secret": secret})
}

func (rl *Relay) adminDeleteServer(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	_ = rl.store.With(func(st *state) (bool, error) {
		delete(st.Servers, id)
		for _, m := range st.Members {
			delete(m.Scopes, id)
		}
		return true, nil
	})
	writeJSON(w, 200, map[string]any{"ok": true})
}

type memberInput struct {
	Name   string              `json:"name"`
	Role   string              `json:"role"`
	Scopes map[string][]string `json:"scopes"`
}

func (in *memberInput) validate(st *state) error {
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" || len(in.Name) > 64 {
		return errors.New("name is required (max 64)")
	}
	if !roleOK[in.Role] {
		return errors.New("role must be admin, operator or viewer")
	}
	if in.Scopes == nil {
		in.Scopes = map[string][]string{}
	}
	for sid, pats := range in.Scopes {
		if _, ok := st.Servers[sid]; !ok {
			return errors.New("unknown server in scopes: " + sid)
		}
		if len(pats) > 50 {
			return errors.New("too many patterns")
		}
		for _, p := range pats {
			if p == "" || len(p) > 128 {
				return errors.New("bad pattern")
			}
		}
	}
	return nil
}

func (rl *Relay) adminInvite(w http.ResponseWriter, r *http.Request) {
	var in memberInput
	if err := readJSON(r, &in); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	code := randomToken(24)
	var inv Invite
	var mem Member
	err := rl.store.With(func(st *state) (bool, error) {
		if err := in.validate(st); err != nil {
			return false, err
		}
		mem = Member{ID: randomID(), Name: in.Name, Role: in.Role, Scopes: in.Scopes, CreatedAt: time.Now(), ACLVersion: 1}
		st.Members[mem.ID] = &mem
		inv = Invite{ID: randomID(), CodeHash: hashSecret(code), MemberID: mem.ID, ExpiresAt: time.Now().Add(inviteTTL)}
		st.Invites[inv.ID] = &inv
		return true, nil
	})
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"invite_id": inv.ID, "member_id": mem.ID, "code": code, "expires_at": inv.ExpiresAt})
}

func (rl *Relay) adminDeleteInvite(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	_ = rl.store.With(func(st *state) (bool, error) {
		if inv, ok := st.Invites[id]; ok {
			if m, ok := st.Members[inv.MemberID]; ok && m.JoinedAt == nil {
				delete(st.Members, inv.MemberID)
			}
			delete(st.Invites, id)
		}
		return true, nil
	})
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (rl *Relay) adminUpdateMember(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in memberInput
	if err := readJSON(r, &in); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	var out Member
	err := rl.store.With(func(st *state) (bool, error) {
		m, ok := st.Members[id]
		if !ok {
			return false, errors.New("member not found")
		}
		if err := in.validate(st); err != nil {
			return false, err
		}
		m.Name, m.Role, m.Scopes = in.Name, in.Role, in.Scopes
		m.ACLVersion++
		out = *m
		return true, nil
	})
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "acl_version": out.ACLVersion})
}

func (rl *Relay) adminDeleteMember(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	_ = rl.store.With(func(st *state) (bool, error) {
		delete(st.Members, id)
		for k, inv := range st.Invites {
			if inv.MemberID == id {
				delete(st.Invites, k)
			}
		}
		return true, nil
	})
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (rl *Relay) adminSynced(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var in struct {
		Version int `json:"version"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	_ = rl.store.With(func(st *state) (bool, error) {
		if m, ok := st.Members[id]; ok && in.Version > m.Synced {
			m.Synced = in.Version
			return true, nil
		}
		return false, nil
	})
	writeJSON(w, 200, map[string]any{"ok": true})
}

// ---- members ----

func (rl *Relay) redeem(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !rl.limiter.Allow("redeem:" + ip) {
		writeErr(w, 429, "too many attempts, try again later")
		return
	}
	var in struct {
		Code      string `json:"code"`
		PublicKey string `json:"public_key"`
		Device    string `json:"device"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	pk, err := base64.StdEncoding.DecodeString(in.PublicKey)
	if err != nil || len(pk) != ed25519.PublicKeySize {
		writeErr(w, 400, "bad public key")
		return
	}
	if len(in.Device) > 64 {
		in.Device = in.Device[:64]
	}
	token := randomToken(32)
	var mem Member
	err = rl.store.With(func(st *state) (bool, error) {
		h := hashSecret(in.Code)
		for id, inv := range st.Invites {
			if subtle.ConstantTimeCompare([]byte(inv.CodeHash), []byte(h)) != 1 {
				continue
			}
			delete(st.Invites, id) // single use
			if time.Now().After(inv.ExpiresAt) {
				return true, errors.New("invite expired, ask for a new one")
			}
			m, ok := st.Members[inv.MemberID]
			if !ok {
				return true, errors.New("invite was cancelled")
			}
			now := time.Now()
			m.PublicKey = in.PublicKey
			m.TokenHash = hashSecret(token)
			m.Device = in.Device
			m.JoinedAt = &now
			m.ACLVersion++
			mem = *m
			return true, nil
		}
		return false, errors.New("invite not valid")
	})
	if err != nil {
		rl.limiter.Fail("redeem:" + ip)
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"member_id": mem.ID, "token": token, "name": mem.Name, "role": mem.Role})
}

func (rl *Relay) me(w http.ResponseWriter, r *http.Request, m *Member) {
	var servers []serverView
	_ = rl.store.With(func(st *state) (bool, error) {
		for sid := range m.Scopes {
			if s, ok := st.Servers[sid]; ok {
				on, last := rl.hub.Online(sid)
				v := serverView{ID: sid, Name: s.Name, Online: on}
				if !last.IsZero() {
					v.LastSeen = &last
				}
				servers = append(servers, v)
			}
		}
		return false, nil
	})
	sort.Slice(servers, func(i, j int) bool { return servers[i].Name < servers[j].Name })
	if servers == nil {
		servers = []serverView{}
	}
	writeJSON(w, 200, map[string]any{"member_id": m.ID, "name": m.Name, "role": m.Role, "servers": servers,
		"activated": m.Synced >= m.ACLVersion})
}

func (rl *Relay) call(w http.ResponseWriter, r *http.Request, m *Member) {
	sid := r.PathValue("id")
	if _, ok := m.Scopes[sid]; !ok {
		writeErr(w, 403, "no access to this server")
		return
	}
	var req Request
	if err := readJSON(r, &req); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if !strings.HasPrefix(req.Path, "/v1/") || (req.Method != "GET" && req.Method != "POST" && req.Method != "DELETE") {
		writeErr(w, 400, "bad request")
		return
	}
	req.MemberID = m.ID
	rep, err := rl.hub.Call(r.Context(), sid, &req)
	if err != nil {
		code := 504
		if errors.Is(err, errOffline) {
			code = 503
		}
		writeErr(w, code, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(rep.Status)
	_, _ = w.Write([]byte(rep.Body))
}

// ---- agents ----

func (rl *Relay) poll(w http.ResponseWriter, r *http.Request, sid string) {
	reqs := rl.hub.Poll(r.Context(), sid)
	if len(reqs) == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	writeJSON(w, 200, reqs)
}

func (rl *Relay) reply(w http.ResponseWriter, r *http.Request, sid string) {
	var reps []Reply
	if err := json.NewDecoder(r.Body).Decode(&reps); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	n := 0
	for _, rep := range reps {
		if rep.Status < 100 || rep.Status > 599 {
			rep.Status = 502
		}
		if rl.hub.Deliver(sid, rep) {
			n++
		}
	}
	writeJSON(w, 200, map[string]any{"delivered": n})
}

// ---- rate limiting for login-like endpoints ----

type limiter struct {
	mu    sync.Mutex
	fails map[string][]time.Time
}

func newLimiter() *limiter { return &limiter{fails: map[string][]time.Time{}} }

// Allow blocks a key after 10 failures in 15 minutes.
func (l *limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	cut := time.Now().Add(-15 * time.Minute)
	f := l.fails[key]
	for len(f) > 0 && f[0].Before(cut) {
		f = f[1:]
	}
	l.fails[key] = f
	return len(f) < 10
}

func (l *limiter) Fail(key string) {
	l.mu.Lock()
	l.fails[key] = append(l.fails[key], time.Now())
	l.mu.Unlock()
}
