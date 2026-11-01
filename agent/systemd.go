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
