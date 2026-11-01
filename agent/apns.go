package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

// APNs sends push notifications straight to Apple with a token-based (.p8) key.
type APNs struct {
	store *ConfigStore
	http  *http.Client
	queue chan Notification

	// allowed filters which phones get a notification (team members: scope only).
	allowed func(Device, Notification) bool

	mu       sync.Mutex
	jwt      string
	jwtAt    time.Time
	jwtKeyID string
}

func NewAPNs(store *ConfigStore) *APNs {
	return &APNs{
		store: store,
		http:  &http.Client{Timeout: 15 * time.Second}, // net/http negotiates HTTP/2 over TLS
		queue: make(chan Notification, 64),
	}
}

func (a *APNs) Notify(n Notification) {
	select {
	case a.queue <- n:
	default:
		log.Printf("push queue full, dropping: %s", n.Title)
	}
}

func (a *APNs) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case n := <-a.queue:
			if _, err := a.Send(ctx, n); err != nil {
				log.Printf("push failed: %v", err)
			}
		}
	}
}

type PushResult struct {
	Device string `json:"device"`
	Status int    `json:"status"`
	Reason string `json:"reason,omitempty"`
}

func (a *APNs) Send(ctx context.Context, n Notification) ([]PushResult, error) {
	cfg := a.store.Get()
	if !cfg.APNs.Configured() {
		return nil, errors.New("APNs key not configured")
	}
	if len(cfg.Devices) == 0 {
		return nil, errors.New("no devices registered")
	}
	token, err := a.token(cfg.APNs)
	if err != nil {
		return nil, err
	}
	payload, err := json.Marshal(buildPayload(n))
	if err != nil {
		return nil, err
	}
	var results []PushResult
	var stale []string
	for _, d := range cfg.Devices {
		if a.allowed != nil && !a.allowed(d, n) {
			continue
		}
		host := "https://api.push.apple.com"
		if d.Env == "development" {
			host = "https://api.sandbox.push.apple.com"
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+d.Token, bytes.NewReader(payload))
		if err != nil {
			return results, err
		}
		req.Header.Set("authorization", "bearer "+token)
		req.Header.Set("apns-topic", cfg.APNs.BundleID)
		req.Header.Set("apns-push-type", "alert")
		req.Header.Set("apns-priority", "10")
		req.Header.Set("apns-expiration", fmt.Sprint(time.Now().Add(time.Hour).Unix()))
		req.Header.Set("apns-collapse-id", collapseID(n))
		req.Header.Set("content-type", "application/json")
		resp, err := a.http.Do(req)
		if err != nil {
			results = append(results, PushResult{Device: shortToken(d.Token), Reason: err.Error()})
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		var r struct {
			Reason string `json:"reason"`
		}
		_ = json.Unmarshal(body, &r)
		results = append(results, PushResult{Device: shortToken(d.Token), Status: resp.StatusCode, Reason: r.Reason})
		if resp.StatusCode == http.StatusGone || r.Reason == "BadDeviceToken" || r.Reason == "Unregistered" {
			stale = append(stale, d.Token)
		}
		if resp.StatusCode == http.StatusForbidden && (r.Reason == "ExpiredProviderToken" || r.Reason == "InvalidProviderToken") {
			a.mu.Lock()
			a.jwt = ""
			a.mu.Unlock()
		}
	}
	if len(stale) > 0 {
		_, _ = a.store.Update(func(c *Config) error {
			keep := c.Devices[:0]
			for _, d := range c.Devices {
				drop := false
				for _, s := range stale {
					if d.Token == s {
						drop = true
					}
				}
				if !drop {
					keep = append(keep, d)
				}
			}
			c.Devices = keep
			return nil
		})
	}
	return results, nil
}

func buildPayload(n Notification) map[string]any {
	title := n.Title
	if n.Server != "" {
		title = n.Server + " · " + n.Title
	}
	return map[string]any{
		"aps": map[string]any{
			"alert":     map[string]string{"title": title, "body": n.Body},
			"sound":     "default",
			"thread-id": n.Server,
		},
		"server":    n.Server,
		"key":       n.Key,
		"severity":  n.Severity,
		"container": n.Container,
		"resolved":  n.Resolved,
	}
}

// collapseID lets several watchers report the same outage as one notification.
func collapseID(n Notification) string {
	id := n.Server + ":" + n.Key
	if n.Resolved {
		id += ":ok"
	}
	if len(id) <= 64 {
		return id
	}
	h := sha256.Sum256([]byte(id))
	return base64.RawURLEncoding.EncodeToString(h[:])[:43]
}

func shortToken(t string) string {
	if len(t) > 8 {
		return t[:8] + "…"
	}
	return t
}

// token returns a cached provider JWT (Apple allows refresh every 20–60 min).
func (a *APNs) token(c APNsConfig) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.jwt != "" && a.jwtKeyID == c.KeyID && time.Since(a.jwtAt) < 50*time.Minute {
		return a.jwt, nil
	}
	b, err := os.ReadFile(c.KeyPath)
	if err != nil {
		return "", fmt.Errorf("read APNs key: %w", err)
	}
	key, err := parseP8(b)
	if err != nil {
		return "", err
	}
	now := time.Now()
	t, err := makeJWT(key, c.KeyID, c.TeamID, now)
	if err != nil {
		return "", err
	}
	a.jwt, a.jwtAt, a.jwtKeyID = t, now, c.KeyID
	return t, nil
}

func parseP8(b []byte) (*ecdsa.PrivateKey, error) {
	blk, _ := pem.Decode(b)
	if blk == nil {
		return nil, errors.New("APNs key: not a PEM file")
	}
	k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		return nil, fmt.Errorf("APNs key: %w", err)
	}
	ek, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("APNs key: not an EC key")
	}
	return ek, nil
}

// makeJWT builds an ES256 JWT: signature is r||s, each 32 bytes.
func makeJWT(key *ecdsa.PrivateKey, keyID, teamID string, now time.Time) (string, error) {
	enc := base64.RawURLEncoding
	h, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": keyID})
	p, _ := json.Marshal(map[string]any{"iss": teamID, "iat": now.Unix()})
	signing := enc.EncodeToString(h) + "." + enc.EncodeToString(p)
	sum := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, key, sum[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + enc.EncodeToString(sig), nil
}
