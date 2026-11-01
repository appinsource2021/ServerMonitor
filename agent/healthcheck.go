package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Check is one line of a manual health check.
type Check struct {
	ID     string `json:"id"`
	Title  string `json:"title"`
	Status string `json:"status"` // ok, warn, fail, skip
	Detail string `json:"detail"`
	Hint   string `json:"hint,omitempty"`
}

type HealthReport struct {
	Server     string    `json:"server"`
	Time       time.Time `json:"time"`
	DurationMs int64     `json:"duration_ms"`
	Overall    string    `json:"overall"` // ok, warn, fail
	Checks     []Check   `json:"checks"`
}

func level(v, warn, fail float64) string {
	switch {
	case v >= fail:
		return "fail"
	case v >= warn:
		return "warn"
	default:
		return "ok"
	}
}

// RunHealthCheck measures everything fresh instead of using the cached snapshot.
func (s *Server) RunHealthCheck(ctx context.Context) HealthReport {
	t0 := time.Now()
	cfg := s.store.Get()
	var checks []Check
	add := func(c Check) { checks = append(checks, c) }

	// CPU: sample /proc/stat over one second
	if a, err := readCPUTimes(); err == nil {
		time.Sleep(time.Second)
		if b, err := readCPUTimes(); err == nil {
			p := cpuPercent(a, b)
			add(Check{ID: "cpu", Title: "CPU usage", Status: level(p, 85, 97), Detail: fmt.Sprintf("%.0f%% over the last second", p)})
		}
	}
	if l, err := readLoadavg(); err == nil {
		cores := float64(runtime.NumCPU())
		ratio := l[1] / cores
		add(Check{ID: "load", Title: "Load average", Status: level(ratio, 1.0, 2.0),
			Detail: fmt.Sprintf("%.2f / %.2f / %.2f on %d cores", l[0], l[1], l[2], runtime.NumCPU()),
			Hint:   "5-minute load above the core count means processes are waiting for CPU."})
	}
	if m, err := readMeminfo(); err == nil {
		add(Check{ID: "memory", Title: "Memory", Status: level(m.Percent, 85, 95),
			Detail: fmt.Sprintf("%.0f%% used · %s available of %s", m.Percent, humanBytes(m.AvailableBytes), humanBytes(m.TotalBytes))})
		if m.SwapTotalBytes > 0 {
			sp := float64(m.SwapUsedBytes) / float64(m.SwapTotalBytes) * 100
			add(Check{ID: "swap", Title: "Swap", Status: level(sp, 50, 90), Detail: fmt.Sprintf("%.0f%% used (%s)", sp, humanBytes(m.SwapUsedBytes))})
		}
	}

	// disks and inodes
	for _, mnt := range cfg.Disks {
		d, err := diskUsage(mnt)
		if err != nil {
			add(Check{ID: "disk:" + mnt, Title: "Disk " + mnt, Status: "fail", Detail: err.Error()})
			continue
		}
		add(Check{ID: "disk:" + mnt, Title: "Disk " + mnt, Status: level(d.Percent, 85, 95),
			Detail: fmt.Sprintf("%.0f%% used · %s free", d.Percent, humanBytes(d.FreeBytes))})
		var st syscall.Statfs_t
		if syscall.Statfs(mnt, &st) == nil && st.Files > 0 {
			ip := float64(st.Files-st.Ffree) / float64(st.Files) * 100
			add(Check{ID: "inodes:" + mnt, Title: "Inodes " + mnt, Status: level(ip, 85, 95),
				Detail: fmt.Sprintf("%.0f%% used", ip), Hint: "Running out of inodes blocks new files even with free space."})
		}
	}

	// Docker
	snap := s.collector.Snapshot()
	var ping struct{}
	pctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	derr := s.docker.getJSON(pctx, "/version", &ping)
	cancel()
	if derr != nil {
		st := "skip"
		if _, err := os.Stat(cfg.DockerSocket); err == nil {
			st = "fail"
		}
		add(Check{ID: "docker", Title: "Docker engine", Status: st, Detail: derr.Error()})
	} else {
		add(Check{ID: "docker", Title: "Docker engine", Status: "ok", Detail: "responding"})
		var bad []string
		for _, c := range snap.Containers {
			if c.Ignored {
				continue
			}
			switch {
			case containerDown(c, time.Now()):
				bad = append(bad, c.Name+" (exited "+strconv.Itoa(c.ExitCode)+")")
			case c.State == "restarting":
				bad = append(bad, c.Name+" (restarting)")
			case c.Health == "unhealthy":
				bad = append(bad, c.Name+" (unhealthy)")
			}
		}
		st, detail := "ok", fmt.Sprintf("%d containers, all fine", len(snap.Containers))
		if len(bad) > 0 {
			st, detail = "fail", strings.Join(bad, ", ")
		}
		add(Check{ID: "containers", Title: "Containers", Status: st, Detail: detail})
	}

	// systemd
	if svcs, err := listServices(ctx); err == nil {
		var failed []string
		for _, sv := range svcs {
			if sv.Active == "failed" {
				failed = append(failed, strings.TrimSuffix(sv.Name, ".service"))
			}
		}
		st, detail := "ok", "no failed units"
		if len(failed) > 0 {
			st, detail = "fail", strings.Join(failed, ", ")
		}
		add(Check{ID: "systemd", Title: "System services", Status: st, Detail: detail})
	}

	// OOM kills in the last 24 h
	if out, err := runQuick(ctx, "journalctl", "-k", "--since", "-24h", "--no-pager", "-q", "-g", "Out of memory|oom-kill"); err == nil || exitCode(err) == 1 {
		n := 0
		for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
			if strings.TrimSpace(l) != "" {
				n++
			}
		}
		st, detail := "ok", "none in the last 24 h"
		if n > 0 {
			st, detail = "warn", fmt.Sprintf("%d kernel OOM messages in the last 24 h", n)
		}
		add(Check{ID: "oom", Title: "Out-of-memory kills", Status: st, Detail: detail})
	}

	// clock
	if out, err := runQuick(ctx, "timedatectl", "show", "-p", "NTPSynchronized", "--value"); err == nil {
		st, detail := "ok", "synchronized"
		if strings.TrimSpace(out) != "yes" {
			st, detail = "warn", "not synchronized (NTP)"
		}
		add(Check{ID: "clock", Title: "Clock", Status: st, Detail: detail, Hint: "A wrong clock breaks TLS and team access."})
	}

	// pending reboot
	if _, err := os.Stat("/var/run/reboot-required"); err == nil {
		add(Check{ID: "reboot", Title: "Reboot", Status: "warn", Detail: "a reboot is required after updates"})
	} else {
		add(Check{ID: "reboot", Title: "Reboot", Status: "ok", Detail: "not required"})
	}

	// other servers
	if len(snap.Peers) > 0 {
		var down []string
		for _, p := range snap.Peers {
			if !p.Reachable {
				down = append(down, p.Name)
			}
		}
		st, detail := "ok", fmt.Sprintf("%d reachable", len(snap.Peers))
		if len(down) > 0 {
			st, detail = "fail", "unreachable: "+strings.Join(down, ", ")
		}
		add(Check{ID: "peers", Title: "Other servers", Status: st, Detail: detail})
	}

	// agent itself
	add(Check{ID: "agent", Title: "Monitoring agent", Status: "ok", Detail: "srvmon-agent " + version})

	overall := "ok"
	for _, c := range checks {
		if c.Status == "fail" {
			overall = "fail"
			break
		}
		if c.Status == "warn" {
			overall = "warn"
		}
	}
	return HealthReport{Server: cfg.Name, Time: time.Now(), DurationMs: time.Since(t0).Milliseconds(), Overall: overall, Checks: checks}
}

func runQuick(ctx context.Context, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	return string(out), err
}

func (s *Server) healthCheck(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, s.RunHealthCheck(r.Context()))
}

// exitCode returns the process exit code, or -1 when it did not run.
func exitCode(err error) int {
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode()
	}
	return -1
}
