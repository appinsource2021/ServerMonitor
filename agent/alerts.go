package main

import (
	"fmt"
	"log"
	"sort"
	"sync"
	"time"
)

type Alert struct {
	Key       string     `json:"key"`
	Server    string     `json:"server"` // server the alert is about (peer name for unreachable)
	Severity  string     `json:"severity"`
	Title     string     `json:"title"`
	Message   string     `json:"message"`
	Container string     `json:"container,omitempty"`
	Service   string     `json:"service,omitempty"`
	Since     time.Time  `json:"since"`
	Resolved  *time.Time `json:"resolved,omitempty"`
	Notified  bool       `json:"notified"`
}

// Notification is what reaches the phone.
type Notification struct {
	Server    string `json:"server"`
	Key       string `json:"key"`
	Severity  string `json:"severity"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	Container string `json:"container,omitempty"`
	Resolved  bool   `json:"resolved"`
}

type Notifier interface {
	Notify(n Notification)
}

type candidate struct {
	Alert
	hold time.Duration
}

type restartSample struct {
	t     time.Time
	count int
}

type AlertEngine struct {
	mu        sync.Mutex
	pending   map[string]time.Time
	active    map[string]*Alert
	lastPush  map[string]time.Time
	history   []Alert
	restarts  map[string][]restartSample
	notifier  Notifier
	startedAt time.Time
}

func NewAlertEngine(n Notifier) *AlertEngine {
	return &AlertEngine{
		pending:   map[string]time.Time{},
		active:    map[string]*Alert{},
		lastPush:  map[string]time.Time{},
		restarts:  map[string][]restartSample{},
		notifier:  n,
		startedAt: time.Now(),
	}
}

func (e *AlertEngine) Active() []Alert {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := make([]Alert, 0, len(e.active))
	for _, a := range e.active {
		out = append(out, *a)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Severity != out[j].Severity {
			return out[i].Severity == "critical"
		}
		return out[i].Since.Before(out[j].Since)
	})
	return out
}

func (e *AlertEngine) History() []Alert {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := make([]Alert, len(e.history))
	for i := range e.history {
		out[len(e.history)-1-i] = e.history[i] // newest first
	}
	return out
}

func (e *AlertEngine) Evaluate(now time.Time, s Snapshot, cfg Config) {
	cands := e.candidates(now, s, cfg)

	e.mu.Lock()
	var toSend []Notification
	seen := map[string]bool{}
	cooldown := time.Duration(cfg.Rules.CooldownSeconds) * time.Second
	for _, c := range cands {
		seen[c.Key] = true
		if a, ok := e.active[c.Key]; ok {
			a.Message = c.Message // keep numbers fresh
			continue
		}
		first, ok := e.pending[c.Key]
		if !ok {
			first = now
			e.pending[c.Key] = now
		}
		if now.Sub(first) < c.hold {
			continue
		}
		a := c.Alert
		a.Since = first
		if last, ok := e.lastPush[a.Key]; !ok || now.Sub(last) >= cooldown {
			a.Notified = true
			e.lastPush[a.Key] = now
			toSend = append(toSend, Notification{Server: a.Server, Key: a.Key, Severity: a.Severity,
				Title: a.Title, Body: a.Message, Container: a.Container})
		}
		e.active[a.Key] = &a
		delete(e.pending, a.Key)
		log.Printf("alert firing: %s — %s", a.Title, a.Message)
	}
	for k := range e.pending {
		if !seen[k] {
			delete(e.pending, k)
		}
	}
	for k, a := range e.active {
		if seen[k] {
			continue
		}
		t := now
		a.Resolved = &t
		e.history = append(e.history, *a)
		if len(e.history) > 200 {
			e.history = e.history[len(e.history)-200:]
		}
		delete(e.active, k)
		log.Printf("alert resolved: %s", a.Title)
		if cfg.Rules.NotifyResolved && a.Notified {
			toSend = append(toSend, Notification{Server: a.Server, Key: a.Key, Severity: "resolved",
				Title: "Resolved · " + a.Title, Body: "Back to normal after " + humanDuration(now.Sub(a.Since)),
				Container: a.Container, Resolved: true})
		}
	}
	e.mu.Unlock()

	if e.notifier != nil {
		for _, n := range toSend {
			e.notifier.Notify(n)
		}
	}
}

func (e *AlertEngine) candidates(now time.Time, s Snapshot, cfg Config) []candidate {
	r := cfg.Rules
	me := cfg.Name
	var out []candidate
	add := func(key, sev, title, msg string, hold int, container, service string) {
		out = append(out, candidate{
			Alert: Alert{Key: key, Server: me, Severity: sev, Title: title, Message: msg, Container: container, Service: service},
			hold:  time.Duration(hold) * time.Second,
		})
	}
	if r.CPU.Enabled && s.CPUPercent >= r.CPU.Percent {
		add("cpu", sevFor(s.CPUPercent, r.CPU.Percent), fmt.Sprintf("CPU above %.0f%%", r.CPU.Percent),
			fmt.Sprintf("CPU at %.0f%% · load %.2f", s.CPUPercent, s.Load[0]), r.CPU.ForSeconds, "", "")
	}
	if r.Memory.Enabled && s.Memory.TotalBytes > 0 && s.Memory.Percent >= r.Memory.Percent {
		add("memory", sevFor(s.Memory.Percent, r.Memory.Percent), fmt.Sprintf("Memory above %.0f%%", r.Memory.Percent),
			fmt.Sprintf("Memory at %.0f%% · %s free", s.Memory.Percent, humanBytes(s.Memory.AvailableBytes)), r.Memory.ForSeconds, "", "")
	}
	if r.Disk.Enabled {
		for _, d := range s.Disks {
			if d.Percent >= r.Disk.Percent {
				add("disk:"+d.Mount, sevFor(d.Percent, r.Disk.Percent), "Disk "+d.Mount+fmt.Sprintf(" above %.0f%%", r.Disk.Percent),
					fmt.Sprintf("%s at %.0f%% · %s free", d.Mount, d.Percent, humanBytes(d.FreeBytes)), r.Disk.ForSeconds, "", "")
			}
		}
	}

	e.mu.Lock()
	window := time.Duration(r.RestartLoop.WindowSeconds) * time.Second
	alive := map[string]bool{}
	for _, c := range s.Containers {
		alive[c.Name] = true
		hist := append(e.restarts[c.Name], restartSample{t: now, count: c.RestartCount})
		for len(hist) > 0 && now.Sub(hist[0].t) > window {
			hist = hist[1:]
		}
		e.restarts[c.Name] = hist
	}
	for name := range e.restarts {
		if !alive[name] {
			delete(e.restarts, name)
		}
	}
	restartsIn := func(name string) int {
		h := e.restarts[name]
		if len(h) < 2 {
			return 0
		}
		return h[len(h)-1].count - h[0].count
	}
	for _, c := range s.Containers {
		if c.Ignored {
			continue
		}
		if r.ContainerDown.Enabled && containerDown(c, now) {
			reason := fmt.Sprintf("exited with code %d", c.ExitCode)
			if c.OOMKilled {
				reason = "killed: out of memory"
			}
			if c.State == "dead" {
				reason = "container is dead"
			}
			add("container_down:"+c.Name, "critical", c.Name+" stopped", reason, r.ContainerDown.ForSeconds, c.Name, "")
		}
		if r.Unhealthy.Enabled && c.State == "running" && c.Health == "unhealthy" {
			add("unhealthy:"+c.Name, "warning", c.Name+" unhealthy", "Health check failing", r.Unhealthy.ForSeconds, c.Name, "")
		}
		if r.RestartLoop.Enabled {
			if n := restartsIn(c.Name); n >= r.RestartLoop.Count {
				add("restart_loop:"+c.Name, "critical", c.Name+" restart loop",
					fmt.Sprintf("Restarted %d× in %s", n, humanDuration(window)), 0, c.Name, "")
			}
		}
	}
	e.mu.Unlock()

	if r.SystemdFailed.Enabled {
		for _, sv := range s.Services {
			if sv.Active == "failed" {
				add("systemd:"+sv.Name, "critical", sv.Name+" failed", "systemd unit is in failed state", r.SystemdFailed.ForSeconds, "", sv.Name)
			}
		}
	}
	if r.PeerUnreachable.Enabled {
		hold := time.Duration(r.PeerUnreachable.ForSeconds) * time.Second
		for _, p := range s.Peers {
			if !p.Reachable && now.Sub(p.LastOK) >= hold {
				out = append(out, candidate{
					Alert: Alert{Key: "peer_down:" + p.Name, Server: p.Name, Severity: "critical",
						Title:   p.Name + " unreachable",
						Message: fmt.Sprintf("No SSH response from %s for %s (seen from %s)", p.Host, humanDuration(now.Sub(p.LastOK)), me)},
				})
			}
		}
	}
	return out
}

// containerDown ignores clean stops (0, 143 = SIGTERM from docker stop)
// and anything that finished more than a day ago.
func containerDown(c Container, now time.Time) bool {
	if c.State == "dead" {
		return true
	}
	if c.State != "exited" {
		return false
	}
	if !c.OOMKilled && (c.ExitCode == 0 || c.ExitCode == 143) {
		return false
	}
	if c.FinishedAt != "" {
		if t, err := time.Parse(time.RFC3339Nano, c.FinishedAt); err == nil && now.Sub(t) > 24*time.Hour {
			return false
		}
	}
	return true
}

func sevFor(v, threshold float64) string {
	if v >= threshold+((100-threshold)/2) {
		return "critical"
	}
	return "warning"
}

func humanDuration(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%d s", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%d min", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%.1f h", d.Hours())
	default:
		return fmt.Sprintf("%d d", int(d.Hours()/24))
	}
}

func humanBytes(b uint64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := uint64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}
