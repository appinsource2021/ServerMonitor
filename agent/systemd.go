package main

import (
	"bufio"
	"context"
	"errors"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type Service struct {
	Name        string `json:"name"`
	Load        string `json:"load"`
	Active      string `json:"active"` // active, inactive, failed, activating…
	Sub         string `json:"sub"`    // running, exited, dead, failed…
	Description string `json:"description"`
}

var unitNameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9@._:\\-]*$`)

func listServices(ctx context.Context) ([]Service, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "systemctl", "list-units", "--type=service", "--all",
		"--no-legend", "--no-pager", "--plain").Output()
	if err != nil {
		return nil, err
	}
	return parseListUnits(string(out)), nil
}

func parseListUnits(s string) []Service {
	var out []Service
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		line := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(sc.Text()), "●"))
		f := strings.Fields(line)
		if len(f) < 4 || !strings.HasSuffix(f[0], ".service") {
			continue
		}
		if f[1] == "not-found" {
			continue
		}
		out = append(out, Service{
			Name:        f[0],
			Load:        f[1],
			Active:      f[2],
			Sub:         f[3],
			Description: strings.Join(f[4:], " "),
		})
	}
	return out
}

func serviceLogs(ctx context.Context, unit string, tail int) ([]LogLine, error) {
	if !unitNameRe.MatchString(unit) {
		return nil, errors.New("invalid unit name")
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "journalctl", "-u", unit, "-n", strconv.Itoa(tail),
		"--no-pager", "-o", "short-iso").Output()
	if err != nil {
		return nil, err
	}
	var lines []LogLine
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		t := sc.Text()
		if strings.HasPrefix(t, "-- ") {
			continue
		}
		// short-iso: 2026-10-30T14:02:11+0100 host proc[pid]: message
		if ts, rest, ok := strings.Cut(t, " "); ok && len(ts) >= 19 && ts[4] == '-' {
			if _, msg, ok := strings.Cut(rest, ": "); ok {
				lines = append(lines, LogLine{Time: ts, Stream: "journal", Text: msg})
				continue
			}
		}
		lines = append(lines, LogLine{Stream: "journal", Text: t})
	}
	return lines, nil
}

// --- service actions (agent 0.4.0) ---

// Units the app must never touch: the agent itself, and nothing that would cut the SSH
// path the app arrives on. Restarting sshd is fine (open sessions survive), stopping is not.
var serviceNeverTouch = map[string]bool{"srvmon-agent.service": true}
var serviceNeverStop = map[string]bool{"ssh.service": true, "sshd.service": true, "systemd-logind.service": true, "dbus.service": true}

// systemctlRun is swapped in tests.
var systemctlRun = func(ctx context.Context, args ...string) ([]byte, error) {
	return killableCmd(ctx, "systemctl", args...).CombinedOutput()
}

// serviceAction runs systemctl start|stop|restart on a unit and returns its state afterwards.
// The unit may be given with or without ".service".
func serviceAction(ctx context.Context, unit, action string) (Service, error) {
	if !strings.HasSuffix(unit, ".service") {
		unit += ".service"
	}
	if !unitNameRe.MatchString(unit) {
		return Service{}, errors.New("invalid unit name")
	}
	switch action {
	case "start", "stop", "restart":
	default:
		return Service{}, errors.New("unknown action (start, stop, restart)")
	}
	if serviceNeverTouch[unit] {
		return Service{}, errors.New(unit + " is managed by the app itself; update it from the server list")
	}
	if action != "start" && serviceNeverStop[unit] {
		return Service{}, errors.New(unit + " keeps this connection alive and is never stopped or restarted from the app")
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	if out, err := systemctlRun(ctx, action, unit); err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return Service{}, errors.New(msg)
	}
	return serviceState(ctx, unit)
}

// serviceState reads one unit's state (used right after an action, before the next tick).
func serviceState(ctx context.Context, unit string) (Service, error) {
	out, err := systemctlRun(ctx, "show", unit, "-p", "LoadState,ActiveState,SubState,Description", "--no-pager")
	if err != nil {
		return Service{}, errors.New(strings.TrimSpace(string(out)))
	}
	s := Service{Name: unit}
	for _, line := range strings.Split(string(out), "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch k {
		case "LoadState":
			s.Load = v
		case "ActiveState":
			s.Active = v
		case "SubState":
			s.Sub = v
		case "Description":
			s.Description = v
		}
	}
	return s, nil
}
