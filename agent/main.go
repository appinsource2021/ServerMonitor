// srvmon-agent: lightweight server monitor for the iOS app.
//
//	srvmon-agent run  [-config /etc/srvmon/config.json]   start the daemon
//	srvmon-agent api  [-socket path] METHOD PATH [BODY|-] call the local API (used by the app over SSH)
//	srvmon-agent version
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var version = "0.3.6"

const defaultConfigPath = "/etc/srvmon/config.json"

var configPath = defaultConfigPath

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "run":
		runDaemon(os.Args[2:])
	case "api":
		os.Exit(runAPIClient(os.Args[2:], os.Stdin, os.Stdout, os.Stderr))
	case "version", "--version", "-v":
		fmt.Println(version)
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: srvmon-agent run [-config path] | api [-socket path] METHOD PATH [BODY|-] | version")
	os.Exit(2)
}

func runDaemon(args []string) {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	fs.StringVar(&configPath, "config", defaultConfigPath, "config file")
	_ = fs.Parse(args)
	log.SetFlags(0) // journald adds timestamps

	store, err := LoadConfig(configPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	cfg := store.Get()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	apns := NewAPNs(store)
	go apns.Run(ctx)
	alerts := NewAlertEngine(apns)
	collector := NewCollector(store)
	go collector.Run(ctx, func(s Snapshot) { alerts.Evaluate(time.Now(), s, store.Get()) })

	srv := &Server{store: store, collector: collector, alerts: alerts, apns: apns, docker: NewDockerClient(cfg.DockerSocket),
		nonces: nonceCache{seen: map[string]time.Time{}}}
	apns.allowed = func(d Device, n Notification) bool { return srv.deviceMaySee(d, n) }
	go srv.RunRelay(ctx)
	h := srv.Handler()

	ln, err := listenUnix(cfg.Socket, cfg.SocketGroup)
	if err != nil {
		log.Fatalf("socket: %v", err)
	}
	servers := []*http.Server{{Handler: h, ReadHeaderTimeout: 10 * time.Second}}
	go serve(servers[0], ln)
	log.Printf("srvmon-agent %s (%s) listening on %s", version, cfg.Name, cfg.Socket)

	if cfg.Listen != "" {
		tl, err := net.Listen("tcp", cfg.Listen)
		if err != nil {
			log.Fatalf("listen %s: %v", cfg.Listen, err)
		}
		ts := &http.Server{Handler: TokenAuth(store, h), ReadHeaderTimeout: 10 * time.Second}
		servers = append(servers, ts)
		go serve(ts, tl)
		log.Printf("also listening on tcp %s (token auth)", cfg.Listen)
	}

	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, s := range servers {
		_ = s.Shutdown(shutdown)
	}
	_ = os.Remove(cfg.Socket)
}

func serve(s *http.Server, l net.Listener) {
	if err := s.Serve(l); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("serve: %v", err)
	}
}

// listenUnix creates a socket only root can reach, or root and one group
// (socket_group) so a non-root monitoring user can call the agent.
func listenUnix(path, group string) (net.Listener, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	gid := -1
	if group != "" {
		g, err := user.LookupGroup(group)
		if err != nil {
			return nil, fmt.Errorf("socket_group %q: %w", group, err)
		}
		gid, _ = strconv.Atoi(g.Gid)
	}
	if fi, err := os.Lstat(path); err == nil && fi.Mode()&os.ModeSocket != 0 {
		_ = os.Remove(path)
	}
	old := syscall.Umask(0o177)
	ln, err := net.Listen("unix", path)
	syscall.Umask(old)
	if err != nil {
		return nil, err
	}
	mode, dirMode := os.FileMode(0o600), os.FileMode(0o700)
	if gid >= 0 {
		mode, dirMode = 0o660, 0o750
		if err := os.Chown(dir, -1, gid); err == nil {
			err = os.Chown(path, -1, gid)
		}
		if err != nil {
			ln.Close()
			return nil, err
		}
	}
	if err := os.Chmod(dir, dirMode); err != nil {
		ln.Close()
		return nil, err
	}
	if err := os.Chmod(path, mode); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

// runAPIClient prints "HTTP <code>" then the body, and exits 0 whenever the
// daemon answered, so the app always gets the error body over SSH.
func runAPIClient(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("api", flag.ContinueOnError)
	fs.SetOutput(stderr)
	sock := fs.String("socket", "", "unix socket (default: from config)")
	cfgFile := fs.String("config", defaultConfigPath, "config file")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) < 2 {
		fmt.Fprintln(stderr, "usage: srvmon-agent api [-socket path] METHOD PATH [BODY|-]")
		return 2
	}
	method, path := strings.ToUpper(rest[0]), rest[1]
	if !strings.HasPrefix(path, "/v1/") {
		fmt.Fprintln(stderr, "path must start with /v1/")
		return 2
	}
	var body io.Reader
	if len(rest) > 2 {
		if rest[2] == "-" {
			b, err := io.ReadAll(io.LimitReader(stdin, 1<<20))
			if err != nil {
				fmt.Fprintln(stderr, err)
				return 1
			}
			body = bytes.NewReader(b)
		} else {
			body = strings.NewReader(rest[2])
		}
	}
	socket := *sock
	if socket == "" {
		socket = DefaultConfig().Socket
		if b, err := os.ReadFile(*cfgFile); err == nil {
			var c struct {
				Socket string `json:"socket"`
			}
			if json.Unmarshal(b, &c) == nil && c.Socket != "" {
				socket = c.Socket
			}
		}
	}
	client := &http.Client{
		Timeout: 16 * time.Minute, // disk scans and cleanups can be slow
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", socket)
		}},
	}
	req, err := http.NewRequest(method, "http://agent"+path, body)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintf(stderr, "agent not reachable on %s: %v\n", socket, err)
		return 1
	}
	defer resp.Body.Close()
	fmt.Fprintf(stdout, "HTTP %d\n", resp.StatusCode)
	_, _ = io.Copy(stdout, resp.Body)
	return 0
}
