package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Server is an agent that connects outbound to the relay.
type Server struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	SecretHash string    `json:"secret_hash"`
	CreatedAt  time.Time `json:"created_at"`
}

// Member is a non-SSH user of the app. Role and scopes here are the admin's
// record; the agent enforces its own copy, pushed by the admin app over SSH.
type Member struct {
	ID         string              `json:"id"`
	Name       string              `json:"name"`
	Role       string              `json:"role"`   // admin, operator, viewer
	Scopes     map[string][]string `json:"scopes"` // server id -> patterns
	PublicKey  string              `json:"public_key,omitempty"`
	TokenHash  string              `json:"token_hash,omitempty"`
	Device     string              `json:"device,omitempty"`
	CreatedAt  time.Time           `json:"created_at"`
	JoinedAt   *time.Time          `json:"joined_at,omitempty"`
	LastSeen   *time.Time          `json:"last_seen,omitempty"`
	ACLVersion int                 `json:"acl_version"`
	Synced     int                 `json:"synced_version"`
}

type Invite struct {
	ID        string    `json:"id"`
	CodeHash  string    `json:"code_hash"`
	MemberID  string    `json:"member_id"`
	ExpiresAt time.Time `json:"expires_at"`
}

type state struct {
	Servers map[string]*Server `json:"servers"`
	Members map[string]*Member `json:"members"`
	Invites map[string]*Invite `json:"invites"`
}

// Store is a small JSON-file database; writes are atomic renames.
type Store struct {
	mu   sync.Mutex
	path string
	st   state
}

func OpenStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	s := &Store{path: filepath.Join(dir, "relay.json")}
	s.st = state{Servers: map[string]*Server{}, Members: map[string]*Member{}, Invites: map[string]*Invite{}}
	b, err := os.ReadFile(s.path)
	switch {
	case err == nil:
		if err := json.Unmarshal(b, &s.st); err != nil {
			return nil, err
		}
		if s.st.Servers == nil {
			s.st.Servers = map[string]*Server{}
		}
		if s.st.Members == nil {
			s.st.Members = map[string]*Member{}
		}
		if s.st.Invites == nil {
			s.st.Invites = map[string]*Invite{}
		}
	case errors.Is(err, os.ErrNotExist):
	default:
		return nil, err
	}
	return s, nil
}

// With runs fn under the lock and saves if fn reports a change.
func (s *Store) With(fn func(st *state) (changed bool, err error)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	changed, err := fn(&s.st)
	if err != nil {
		return err
	}
	if changed {
		return s.saveLocked()
	}
	return nil
}

func (s *Store) saveLocked() error {
	b, err := json.MarshalIndent(s.st, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".relay-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), s.path)
}

func randomToken(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func randomID() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func hashSecret(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
