package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// ThresholdRule fires when a percentage stays above Percent for ForSeconds.
type ThresholdRule struct {
	Enabled    bool    `json:"enabled"`
	Percent    float64 `json:"percent"`
	ForSeconds int     `json:"for_seconds"`
}

type ToggleRule struct {
	Enabled    bool `json:"enabled"`
	ForSeconds int  `json:"for_seconds"`
}

type RestartRule struct {
	Enabled       bool `json:"enabled"`
	Count         int  `json:"count"`
	WindowSeconds int  `json:"window_seconds"`
}

type Rules struct {
	CPU             ThresholdRule `json:"cpu"`
	Memory          ThresholdRule `json:"memory"`
	Disk            ThresholdRule `json:"disk"`
	ContainerDown   ToggleRule    `json:"container_down"`
	Unhealthy       ToggleRule    `json:"unhealthy"`
	RestartLoop     RestartRule   `json:"restart_loop"`
	SystemdFailed   ToggleRule    `json:"systemd_failed"`
	PeerUnreachable ToggleRule    `json:"peer_unreachable"`
	CooldownSeconds int           `json:"cooldown_seconds"`
	NotifyResolved  bool          `json:"notify_resolved"`
}

func DefaultRules() Rules {
	return Rules{
		CPU:             ThresholdRule{Enabled: true, Percent: 90, ForSeconds: 300},
		Memory:          ThresholdRule{Enabled: true, Percent: 85, ForSeconds: 120},
		Disk:            ThresholdRule{Enabled: true, Percent: 85, ForSeconds: 0},
		ContainerDown:   ToggleRule{Enabled: true, ForSeconds: 0},
		Unhealthy:       ToggleRule{Enabled: true, ForSeconds: 60},
		RestartLoop:     RestartRule{Enabled: true, Count: 3, WindowSeconds: 600},
		SystemdFailed:   ToggleRule{Enabled: true, ForSeconds: 0},
		PeerUnreachable: ToggleRule{Enabled: true, ForSeconds: 120},
		CooldownSeconds: 900,
		NotifyResolved:  true,
	}
}

type APNsConfig struct {
	KeyPath  string `json:"key_path"`
	KeyID    string `json:"key_id"`
	TeamID   string `json:"team_id"`
	BundleID string `json:"bundle_id"`
}

func (a APNsConfig) Configured() bool {
	return a.KeyPath != "" && a.KeyID != "" && a.TeamID != "" && a.BundleID != ""
}

// Device is a phone that receives push notifications.
type Device struct {
	Token    string `json:"token"`
	Env      string `json:"env"` // "development" or "production"
	Name     string `json:"name,omitempty"`
	MemberID string `json:"member_id,omitempty"` // empty = admin phone (SSH)
}

// Member is a team member reaching this agent through the relay. The admin app
// pushes this list over SSH; it is the only authority on what a member may see.
type Member struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Role      string   `json:"role"`       // admin, operator, viewer
	PublicKey string   `json:"public_key"` // base64 Ed25519, signs every request
	Scopes    []string `json:"scopes"`     // container patterns on this server
}

type RelayConfig struct {
	URL      string `json:"url"`
	ServerID string `json:"server_id"`
	Secret   string `json:"secret"`
}

func (r RelayConfig) Configured() bool { return r.URL != "" && r.ServerID != "" && r.Secret != "" }

// Peer is another server this agent watches (TCP check on its SSH port).
type Peer struct {
	Name string `json:"name"`
	Host string `json:"host"`
	Port int    `json:"port"`
}

type Config struct {
	Name         string      `json:"name"`
	Socket       string      `json:"socket"`
	SocketGroup  string      `json:"socket_group,omitempty"` // e.g. "srvmon": lets a non-root monitoring user use the agent
	Listen       string      `json:"listen,omitempty"`       // optional TCP listener, requires Token
	Token        string      `json:"token,omitempty"`
	Disks        []string    `json:"disks,omitempty"`
	DockerSocket string      `json:"docker_socket,omitempty"`
	AllowActions bool        `json:"allow_actions"`
	Rules        Rules       `json:"rules"`
	APNs         APNsConfig  `json:"apns"`
	Devices      []Device    `json:"devices"`
	Peers        []Peer      `json:"peers"`
	Members      []Member    `json:"members"`
	Relay        RelayConfig `json:"relay"`
}

func DefaultConfig() Config {
	host, _ := os.Hostname()
	return Config{
		Name:         host,
		Socket:       "/run/srvmon/agent.sock",
		Disks:        []string{"/"},
		DockerSocket: "/var/run/docker.sock",
		Rules:        DefaultRules(),
		Devices:      []Device{},
		Peers:        []Peer{},
		Members:      []Member{},
	}
}

func (c *Config) applyDefaults() {
	d := DefaultConfig()
	if c.Name == "" {
		c.Name = d.Name
	}
	if c.Socket == "" {
		c.Socket = d.Socket
	}
	if len(c.Disks) == 0 {
		c.Disks = d.Disks
	}
	if c.DockerSocket == "" {
		c.DockerSocket = d.DockerSocket
	}
	if c.Rules.CooldownSeconds <= 0 {
		c.Rules.CooldownSeconds = d.Rules.CooldownSeconds
	}
	if c.Rules.RestartLoop.Count <= 0 {
		c.Rules.RestartLoop.Count = d.Rules.RestartLoop.Count
	}
	if c.Rules.RestartLoop.WindowSeconds <= 0 {
		c.Rules.RestartLoop.WindowSeconds = d.Rules.RestartLoop.WindowSeconds
	}
	if c.Devices == nil {
		c.Devices = []Device{}
	}
	if c.Peers == nil {
		c.Peers = []Peer{}
	}
	if c.Members == nil {
		c.Members = []Member{}
	}
	for i := range c.Peers {
		if c.Peers[i].Port == 0 {
			c.Peers[i].Port = 22
		}
	}
}

func (c Config) Validate() error {
	if c.Listen != "" && len(c.Token) < 24 {
		return errors.New("listen requires a token of at least 24 characters")
	}
	for _, d := range c.Devices {
		if d.Env != "development" && d.Env != "production" {
			return fmt.Errorf("device env must be development or production, got %q", d.Env)
		}
	}
	return nil
}

// ConfigStore holds the live config and persists changes atomically.
type ConfigStore struct {
	mu   sync.RWMutex
	cfg  Config
	path string
}

func LoadConfig(path string) (*ConfigStore, error) {
	cfg := DefaultConfig()
	b, err := os.ReadFile(path)
	switch {
	case err == nil:
		cfg = Config{}
		if err := json.Unmarshal(b, &cfg); err != nil {
			return nil, fmt.Errorf("parse %s: %w", path, err)
		}
		cfg.applyDefaults()
	case errors.Is(err, os.ErrNotExist):
		// first start: write defaults so the app can edit them
	default:
		return nil, err
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	s := &ConfigStore{cfg: cfg, path: path}
	if errors.Is(err, os.ErrNotExist) {
		if werr := s.save(cfg); werr != nil {
			return nil, werr
		}
	}
	return s, nil
}

// Get returns a deep copy of the config.
func (s *ConfigStore) Get() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	c := s.cfg
	c.Disks = append([]string(nil), s.cfg.Disks...)
	c.Devices = append([]Device{}, s.cfg.Devices...)
	c.Peers = append([]Peer{}, s.cfg.Peers...)
	c.Members = append([]Member{}, s.cfg.Members...)
	return c
}

// Update applies fn to a copy, validates, saves and swaps it in.
func (s *ConfigStore) Update(fn func(*Config) error) (Config, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.cfg
	c.Disks = append([]string(nil), s.cfg.Disks...)
	c.Devices = append([]Device{}, s.cfg.Devices...)
	c.Peers = append([]Peer{}, s.cfg.Peers...)
	c.Members = append([]Member{}, s.cfg.Members...)
	if err := fn(&c); err != nil {
		return s.cfg, err
	}
	c.applyDefaults()
	if err := c.Validate(); err != nil {
		return s.cfg, err
	}
	if err := s.save(c); err != nil {
		return s.cfg, err
	}
	s.cfg = c
	return c, nil
}

func (s *ConfigStore) save(c Config) error {
	if s.path == "" {
		return nil
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".config-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), s.path)
}
