package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Process is one row of GET /v1/processes.
type Process struct {
	PID        int     `json:"pid"`
	Name       string  `json:"name"`
	Command    string  `json:"command"`
	User       string  `json:"user"`
	State      string  `json:"state"`       // R running, S sleeping, D waiting on disk, Z zombie…
	CPUPercent float64 `json:"cpu_percent"` // share of the whole host over the sample, like the CPU gauge
	MemBytes   uint64  `json:"mem_bytes"`
	MemPercent float64 `json:"mem_percent"`
	Threads    int     `json:"threads"`
	Container  string  `json:"container,omitempty"`
}

const (
	processSample  = time.Second
	processTopEach = 60  // the busiest by CPU plus the biggest by memory go to the app
	processCmdMax  = 400 // characters of the command line
)

type procStat struct {
	name    string
	state   string
	ticks   uint64 // utime + stime
	threads int
	rss     uint64 // pages
}

// parseProcStat reads /proc/<pid>/stat. The name sits in parentheses and may itself contain
// spaces and parentheses, so the fields are counted from the last ")".
func parseProcStat(s string) (procStat, error) {
	open, end := strings.IndexByte(s, '('), strings.LastIndexByte(s, ')')
	if open < 0 || end < open {
		return procStat{}, errors.New("malformed stat")
	}
	f := strings.Fields(s[end+1:])
	if len(f) < 22 {
		return procStat{}, errors.New("short stat")
	}
	ut, err1 := strconv.ParseUint(f[11], 10, 64)
	st, err2 := strconv.ParseUint(f[12], 10, 64)
	th, err3 := strconv.Atoi(f[17])
	rss, err4 := strconv.ParseInt(f[21], 10, 64)
	if err := errors.Join(err1, err2, err3, err4); err != nil {
		return procStat{}, err
	}
	if rss < 0 {
		rss = 0
	}
	return procStat{name: s[open+1 : end], state: f[0], ticks: ut + st, threads: th, rss: uint64(rss)}, nil
}

func readProcTicks() map[int]procStat {
	out := map[int]procStat{}
	entries, err := os.ReadDir(procRoot)
	if err != nil {
		return out
	}
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		// a process may exit between the listing and the read
		b, err := os.ReadFile(filepath.Join(procRoot, e.Name(), "stat"))
		if err != nil {
			continue
		}
		if st, err := parseProcStat(string(b)); err == nil {
			out[pid] = st
		}
	}
	return out
}

var cgroupContainerRe = regexp.MustCompile(`docker[-/]([0-9a-f]{64})`)

// processContainer names the Docker container a process belongs to, from its cgroup.
func processContainer(pid int, containers []Container) string {
	b, err := os.ReadFile(filepath.Join(procRoot, strconv.Itoa(pid), "cgroup"))
	if err != nil {
		return ""
	}
	m := cgroupContainerRe.FindSubmatch(b)
	if m == nil {
		return ""
	}
	id := string(m[1])
	for _, c := range containers {
		if c.ID != "" && strings.HasPrefix(id, c.ID) {
			return c.Name
		}
	}
	return ""
}

// userCache: one /etc/passwd lookup per uid for the agent's lifetime.
var userCache sync.Map

func processUser(pid int) string {
	fi, err := os.Stat(filepath.Join(procRoot, strconv.Itoa(pid)))
	if err != nil {
		return ""
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	uid := strconv.FormatUint(uint64(st.Uid), 10)
	if v, ok := userCache.Load(uid); ok {
		return v.(string)
	}
	name := uid
	if u, err := user.LookupId(uid); err == nil {
		name = u.Username
	}
	userCache.Store(uid, name)
	return name
}

func processCommand(pid int) string {
	b, err := os.ReadFile(filepath.Join(procRoot, strconv.Itoa(pid), "cmdline"))
	if err != nil {
		return ""
	}
	s := strings.TrimSpace(strings.ReplaceAll(string(b), "\x00", " "))
	if r := []rune(s); len(r) > processCmdMax {
		s = string(r[:processCmdMax]) + "…"
	}
	return s
}

// buildProcesses compares two samples. dTotal is how far the host's CPU clock moved in between,
// over all cores, so ticks/dTotal is already a share of the whole host.
func buildProcesses(before, after map[int]procStat, dTotal uint64, memTotal uint64, containers []Container) ([]Process, int) {
	page := uint64(os.Getpagesize())
	all := make([]Process, 0, len(after))
	for pid, st := range after {
		cmd := processCommand(pid)
		if cmd == "" && st.state != "Z" {
			continue // kernel thread
		}
		p := Process{PID: pid, Name: st.name, Command: cmd, State: st.state, Threads: st.threads, MemBytes: st.rss * page}
		// a process that started during the sample counts from zero; one reused pid cannot go backwards
		if prev, ok := before[pid]; ok && dTotal > 0 && st.ticks >= prev.ticks {
			p.CPUPercent = min(100, round1(float64(st.ticks-prev.ticks)/float64(dTotal)*100))
		}
		if memTotal > 0 {
			p.MemPercent = round1(float64(p.MemBytes) / float64(memTotal) * 100)
		}
		all = append(all, p)
	}
	total := len(all)

	sort.Slice(all, func(i, j int) bool {
		if all[i].CPUPercent != all[j].CPUPercent {
			return all[i].CPUPercent > all[j].CPUPercent
		}
		return all[i].PID < all[j].PID
	})
	keep := map[int]Process{}
	for i := 0; i < len(all) && i < processTopEach; i++ {
		keep[all[i].PID] = all[i]
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].MemBytes != all[j].MemBytes {
			return all[i].MemBytes > all[j].MemBytes
		}
		return all[i].PID < all[j].PID
	})
	for i := 0; i < len(all) && i < processTopEach; i++ {
		keep[all[i].PID] = all[i]
	}
	out := make([]Process, 0, len(keep))
	for _, p := range keep {
		p.User = processUser(p.PID)
		p.Container = processContainer(p.PID, containers)
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].CPUPercent != out[j].CPUPercent {
			return out[i].CPUPercent > out[j].CPUPercent
		}
		return out[i].MemBytes > out[j].MemBytes
	})
	return out, total
}

// GET /v1/processes: admin over SSH only. Command lines can hold passwords, so HandleMember
// never routes it.
func (s *Server) processes(w http.ResponseWriter, r *http.Request) {
	t0, err := readCPUTimes()
	if err != nil {
		writeErr(w, 500, "cannot read CPU times: "+err.Error())
		return
	}
	before := readProcTicks()
	if err := sleepCtx(r.Context(), processSample); err != nil {
		writeErr(w, 499, "cancelled")
		return
	}
	after := readProcTicks()
	t1, err := readCPUTimes()
	if err != nil {
		writeErr(w, 500, "cannot read CPU times: "+err.Error())
		return
	}
	snap := s.collector.Snapshot()
	var dTotal uint64
	if t1.Total > t0.Total {
		dTotal = t1.Total - t0.Total
	}
	list, total := buildProcesses(before, after, dTotal, snap.Memory.TotalBytes, snap.Containers)
	writeJSON(w, 200, map[string]any{"processes": list, "total": total, "sample_ms": processSample.Milliseconds()})
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
