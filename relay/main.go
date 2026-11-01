// srvmon-relay: lets team members reach agents without any open port on the servers.
// Agents poll it outbound; member apps call it over HTTPS (TLS is terminated by your reverse proxy).
//
//	RELAY_ADDR=:8080 RELAY_DATA=/data RELAY_ADMIN_TOKEN=<long random> srvmon-relay
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

var version = "0.2.0"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println(version)
		return
	}
	addr := env("RELAY_ADDR", ":8080")
	data := env("RELAY_DATA", "/data")
	store, err := OpenStore(data)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	admin := strings.TrimSpace(os.Getenv("RELAY_ADMIN_TOKEN"))
	if admin == "" {
		// first start without a configured token: create one and keep it next to the data
		p := filepath.Join(data, "admin-token")
		if b, err := os.ReadFile(p); err == nil {
			admin = strings.TrimSpace(string(b))
		} else {
			admin = randomToken(32)
			if err := os.WriteFile(p, []byte(admin+"\n"), 0o600); err != nil {
				log.Fatalf("write admin token: %v", err)
			}
			log.Printf("generated admin token in %s — enter it in the app under Settings › Relay", p)
		}
	}
	if len(admin) < 24 {
		log.Fatal("RELAY_ADMIN_TOKEN must be at least 24 characters")
	}
	rl := &Relay{store: store, hub: NewHub(), adminToken: admin, limiter: newLimiter()}
	srv := &http.Server{Addr: addr, Handler: rl.Handler(), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		log.Printf("srvmon-relay %s listening on %s", version, addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	<-ctx.Done()
	sh, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(sh)
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
