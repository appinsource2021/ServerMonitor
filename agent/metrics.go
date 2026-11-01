package main

import (
	"bufio"
	"errors"
	"io"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

// procRoot lets tests point the readers at fixture files.
var procRoot = "/proc"

type CPUTimes struct {
	Idle  uint64
	Total uint64
}

// parseCPUTimes reads the aggregate "cpu" line of /proc/stat.
func parseCPUTimes(r io.Reader) (CPUTimes, error) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 5 || f[0] != "cpu" {
			continue
		}
		var vals []uint64
		// user nice system idle iowait irq softirq steal (guest is already in user)
		for i := 1; i < len(f) && i <= 8; i++ {
			v, err := strconv.ParseUint(f[i], 10, 64)
			if err != nil {
				return CPUTimes{}, err
			}
			vals = append(vals, v)
		}
		var total uint64
		for _, v := range vals {
			total += v
		}
		idle := vals[3]
		if len(vals) > 4 {
			idle += vals[4]
		}
		return CPUTimes{Idle: idle, Total: total}, nil
	}
	return CPUTimes{}, errors.New("no cpu line in stat")
}

func readCPUTimes() (CPUTimes, error) {
	f, err := os.Open(procRoot + "/stat")
	if err != nil {
		return CPUTimes{}, err
	}
	defer f.Close()
	return parseCPUTimes(f)
}

func cpuPercent(prev, cur CPUTimes) float64 {
	if cur.Total <= prev.Total {
		return 0
	}
	dt := float64(cur.Total - prev.Total)
	di := float64(cur.Idle - prev.Idle)
	if cur.Idle < prev.Idle {
		di = 0
	}
	p := (dt - di) / dt * 100
	if p < 0 {
		return 0
	}
	if p > 100 {
		return 100
	}
	return round1(p)
}

type MemInfo struct {
	TotalBytes     uint64  `json:"total_bytes"`
	UsedBytes      uint64  `json:"used_bytes"`
	AvailableBytes uint64  `json:"available_bytes"`
	Percent        float64 `json:"percent"`
	SwapTotalBytes uint64  `json:"swap_total_bytes"`
	SwapUsedBytes  uint64  `json:"swap_used_bytes"`
}

func parseMeminfo(r io.Reader) (MemInfo, error) {
	vals := map[string]uint64{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		k, rest, ok := strings.Cut(sc.Text(), ":")
		if !ok {
			continue
		}
		f := strings.Fields(rest)
		if len(f) == 0 {
			continue
		}
		v, err := strconv.ParseUint(f[0], 10, 64)
		if err != nil {
			continue
		}
		if len(f) > 1 && f[1] == "kB" {
			v *= 1024
		}
		vals[k] = v
	}
	total := vals["MemTotal"]
	if total == 0 {
		return MemInfo{}, errors.New("MemTotal missing")
	}
	avail, ok := vals["MemAvailable"]
	if !ok {
		avail = vals["MemFree"] + vals["Buffers"] + vals["Cached"]
	}
	if avail > total {
		avail = total
	}
	used := total - avail
	m := MemInfo{
		TotalBytes:     total,
		AvailableBytes: avail,
		UsedBytes:      used,
		Percent:        round1(float64(used) / float64(total) * 100),
		SwapTotalBytes: vals["SwapTotal"],
	}
	if vals["SwapTotal"] >= vals["SwapFree"] {
		m.SwapUsedBytes = vals["SwapTotal"] - vals["SwapFree"]
	}
	return m, nil
}

func readMeminfo() (MemInfo, error) {
	f, err := os.Open(procRoot + "/meminfo")
	if err != nil {
		return MemInfo{}, err
	}
	defer f.Close()
	return parseMeminfo(f)
}

type DiskInfo struct {
	Mount      string  `json:"mount"`
	TotalBytes uint64  `json:"total_bytes"`
	UsedBytes  uint64  `json:"used_bytes"`
	FreeBytes  uint64  `json:"free_bytes"`
	Percent    float64 `json:"percent"`
}

// diskUsage matches df: used / (used + available to unprivileged users).
func diskUsage(mount string) (DiskInfo, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(mount, &st); err != nil {
		return DiskInfo{}, err
	}
	bs := uint64(st.Bsize)
	total := uint64(st.Blocks) * bs
	free := uint64(st.Bfree) * bs
	avail := uint64(st.Bavail) * bs
	used := total - free
	d := DiskInfo{Mount: mount, TotalBytes: total, UsedBytes: used, FreeBytes: avail}
	if used+avail > 0 {
		d.Percent = round1(float64(used) / float64(used+avail) * 100)
	}
	return d, nil
}

func parseLoadavg(s string) ([3]float64, error) {
	var out [3]float64
	f := strings.Fields(s)
	if len(f) < 3 {
		return out, errors.New("bad loadavg")
	}
	for i := 0; i < 3; i++ {
		v, err := strconv.ParseFloat(f[i], 64)
		if err != nil {
			return out, err
		}
		out[i] = v
	}
	return out, nil
}

func readLoadavg() ([3]float64, error) {
	b, err := os.ReadFile(procRoot + "/loadavg")
	if err != nil {
		return [3]float64{}, err
	}
	return parseLoadavg(string(b))
}

func readUptime() float64 {
	b, err := os.ReadFile(procRoot + "/uptime")
	if err != nil {
		return 0
	}
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(f[0], 64)
	return v
}

type NetCounters struct {
	RxBytes uint64
	TxBytes uint64
}

// parseNetDev sums physical-ish interfaces, skipping loopback and container bridges.
func parseNetDev(r io.Reader) NetCounters {
	var c NetCounters
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		name, rest, ok := strings.Cut(sc.Text(), ":")
		if !ok {
			continue
		}
		name = strings.TrimSpace(name)
		if name == "lo" || strings.HasPrefix(name, "veth") || strings.HasPrefix(name, "docker") ||
			strings.HasPrefix(name, "br-") || strings.HasPrefix(name, "virbr") || strings.HasPrefix(name, "cni") ||
			strings.HasPrefix(name, "flannel") || strings.HasPrefix(name, "cali") {
			continue
		}
		f := strings.Fields(rest)
		if len(f) < 9 {
			continue
		}
		rx, _ := strconv.ParseUint(f[0], 10, 64)
		tx, _ := strconv.ParseUint(f[8], 10, 64)
		c.RxBytes += rx
		c.TxBytes += tx
	}
	return c
}

func readNetDev() NetCounters {
	f, err := os.Open(procRoot + "/net/dev")
	if err != nil {
		return NetCounters{}
	}
	defer f.Close()
	return parseNetDev(f)
}

type HostInfo struct {
	Name     string `json:"name"`
	Hostname string `json:"hostname"`
	OS       string `json:"os"`
	Kernel   string `json:"kernel"`
	Arch     string `json:"arch"`
	CPUs     int    `json:"cpus"`
	Agent    string `json:"agent_version"`
}

func readHostInfo(name string) HostInfo {
	h := HostInfo{Name: name, Arch: runtime.GOARCH, CPUs: runtime.NumCPU(), Agent: version}
	h.Hostname, _ = os.Hostname()
	if b, err := os.ReadFile(procRoot + "/sys/kernel/osrelease"); err == nil {
		h.Kernel = strings.TrimSpace(string(b))
	}
	if b, err := os.ReadFile("/etc/os-release"); err == nil {
		h.OS = parseOSRelease(string(b))
	}
	return h
}

func parseOSRelease(s string) string {
	for _, line := range strings.Split(s, "\n") {
		if v, ok := strings.CutPrefix(line, "PRETTY_NAME="); ok {
			return strings.Trim(v, `"'`)
		}
	}
	return ""
}

func round1(v float64) float64 {
	return float64(int64(v*10+0.5)) / 10
}
