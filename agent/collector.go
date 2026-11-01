package main

import (
	"context"
	"log"
	"net"
	"strconv"
	"sync"
	"time"
)

type NetRate struct {
	RxBytesPerSec float64 `json:"rx_bytes_per_sec"`
	TxBytesPerSec float64 `json:"tx_bytes_per_sec"`
}

type PeerStatus struct {
	Peer
	Reachable bool      `json:"reachable"`
	LastOK    time.Time `json:"last_ok"`
	LastCheck time.Time `json:"last_check"`
	LatencyMs float64   `json:"latency_ms"`
	Error     string    `json:"error,omitempty"`
}

type Snapshot struct {
	Time             time.Time    `json:"time"`
	Host             HostInfo     `json:"host"`
	UptimeSeconds    float64      `json:"uptime_seconds"`
	CPUPercent       float64      `json:"cpu_percent"`
	Load             [3]float64   `json:"load"`
	Memory           MemInfo      `json:"memory"`
	Disks            []DiskInfo   `json:"disks"`
	Net              NetRate      `json:"net"`
	DockerAvailable  bool         `json:"docker_available"`
	DockerError      string       `json:"docker_error,omitempty"`
	Containers       []Container  `json:"containers"`
	SystemdAvailable bool         `json:"systemd_available"`
	Services         []Service    `json:"services"`
	Peers            []PeerStatus `json:"peers"`
}

type HistoryPoint struct {
	Time   int64   `json:"t"`
	CPU    float64 `json:"cpu"`
	Memory float64 `json:"mem"`
}

const historyLen = 120 // 1 hour at 30 s

type Collector struct {
	store  *ConfigStore
	docker *DockerCollector
	start  time.Time

	mu       sync.RWMutex
	snap     Snapshot
	history  []HistoryPoint
	prevCPU  CPUTimes
	prevNet  NetCounters
	prevNetT time.Time
	peers    map[string]*PeerStatus
}

func NewCollector(store *ConfigStore) *Collector {
	cfg := store.Get()
	return &Collector{
		store:  store,
		docker: NewDockerCollector(NewDockerClient(cfg.DockerSocket)),
		start:  time.Now(),
		peers:  map[string]*PeerStatus{},
		snap:   Snapshot{Containers: []Container{}, Services: []Service{}, Peers: []PeerStatus{}, Disks: []DiskInfo{}},
	}
}

func (c *Collector) Snapshot() Snapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	s := c.snap
	s.Containers = append([]Container{}, c.snap.Containers...)
	s.Services = append([]Service{}, c.snap.Services...)
	s.Peers = append([]PeerStatus{}, c.snap.Peers...)
	s.Disks = append([]DiskInfo{}, c.snap.Disks...)
	return s
}

func (c *Collector) History() []HistoryPoint {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return append([]HistoryPoint{}, c.history...)
}

// FindContainer matches by short id, full id prefix or name.
func (c *Collector) FindContainer(key string) (Container, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	for _, ct := range c.snap.Containers {
		if ct.ID == key || ct.Name == key || (len(key) >= 12 && len(ct.ID) == 12 && key[:12] == ct.ID) {
			return ct, true
		}
	}
	return Container{}, false
}

// Run starts the collection loops; onTick is called after each fast tick.
func (c *Collector) Run(ctx context.Context, onTick func(Snapshot)) {
	c.prevCPU, _ = readCPUTimes()
	c.prevNet = readNetDev()
	c.prevNetT = time.Now()
	c.collectHost()
	c.collectDocker(ctx)
	c.collectServices(ctx)
	c.checkPeers(ctx)

	fast := time.NewTicker(5 * time.Second)
	dock := time.NewTicker(10 * time.Second)
	slow := time.NewTicker(30 * time.Second)
	defer fast.Stop()
	defer dock.Stop()
	defer slow.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-fast.C:
			c.collectHost()
			if onTick != nil {
				onTick(c.Snapshot())
			}
		case <-dock.C:
			c.collectDocker(ctx)
		case <-slow.C:
			c.recordHistory()
			go c.collectServices(ctx)
			go c.checkPeers(ctx)
		}
	}
}

func (c *Collector) collectHost() {
	cfg := c.store.Get()
	now := time.Now()
	cpuNow, err := readCPUTimes()
	mem, merr := readMeminfo()
	load, _ := readLoadavg()
	netNow := readNetDev()
	disks := make([]DiskInfo, 0, len(cfg.Disks))
	for _, m := range cfg.Disks {
		if d, err := diskUsage(m); err == nil {
			disks = append(disks, d)
		}
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if err == nil {
		c.snap.CPUPercent = cpuPercent(c.prevCPU, cpuNow)
		c.prevCPU = cpuNow
	}
	if merr == nil {
		c.snap.Memory = mem
	}
	if dt := now.Sub(c.prevNetT).Seconds(); dt > 0 && netNow.RxBytes >= c.prevNet.RxBytes && netNow.TxBytes >= c.prevNet.TxBytes {
		c.snap.Net = NetRate{
			RxBytesPerSec: float64(netNow.RxBytes-c.prevNet.RxBytes) / dt,
			TxBytesPerSec: float64(netNow.TxBytes-c.prevNet.TxBytes) / dt,
		}
	}
	c.prevNet, c.prevNetT = netNow, now
	c.snap.Load = load
	c.snap.Disks = disks
	c.snap.UptimeSeconds = readUptime()
	c.snap.Host = readHostInfo(cfg.Name)
	c.snap.Time = now
	if len(c.history) == 0 {
		c.history = append(c.history, HistoryPoint{Time: now.Unix(), CPU: c.snap.CPUPercent, Memory: mem.Percent})
	}
}

func (c *Collector) recordHistory() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.history = append(c.history, HistoryPoint{Time: time.Now().Unix(), CPU: c.snap.CPUPercent, Memory: c.snap.Memory.Percent})
	if len(c.history) > historyLen {
		c.history = c.history[len(c.history)-historyLen:]
	}
}

func (c *Collector) collectDocker(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	list, err := c.docker.Collect(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	if err != nil {
		c.snap.DockerAvailable = false
		c.snap.DockerError = err.Error()
		c.snap.Containers = []Container{}
		return
	}
	c.snap.DockerAvailable = true
	c.snap.DockerError = ""
	c.snap.Containers = list
}

func (c *Collector) collectServices(ctx context.Context) {
	svcs, err := listServices(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	if err != nil {
		c.snap.SystemdAvailable = false
		c.snap.Services = []Service{}
		return
	}
	c.snap.SystemdAvailable = true
	c.snap.Services = svcs
}

func (c *Collector) checkPeers(ctx context.Context) {
	cfg := c.store.Get()
	results := make([]PeerStatus, len(cfg.Peers))
	var wg sync.WaitGroup
	for i, p := range cfg.Peers {
		wg.Add(1)
		go func(i int, p Peer) {
			defer wg.Done()
			addr := net.JoinHostPort(p.Host, strconv.Itoa(p.Port))
			t0 := time.Now()
			d := net.Dialer{Timeout: 5 * time.Second}
			conn, err := d.DialContext(ctx, "tcp", addr)
			st := PeerStatus{Peer: p, LastCheck: time.Now()}
			if err != nil {
				st.Error = err.Error()
			} else {
				conn.Close()
				st.Reachable = true
				st.LatencyMs = round1(float64(time.Since(t0).Microseconds()) / 1000)
			}
			results[i] = st
		}(i, p)
	}
	wg.Wait()

	c.mu.Lock()
	defer c.mu.Unlock()
	next := map[string]*PeerStatus{}
	for i := range results {
		r := results[i]
		key := r.Name + "|" + r.Host
		if prev, ok := c.peers[key]; ok {
			r.LastOK = prev.LastOK
		} else {
			r.LastOK = c.start // grace period from agent start
		}
		if r.Reachable {
			r.LastOK = r.LastCheck
		}
		next[key] = &r
		results[i] = r
	}
	c.peers = next
	c.snap.Peers = results
	for _, r := range results {
		if !r.Reachable {
			log.Printf("peer %s (%s) unreachable: %s", r.Name, r.Host, r.Error)
		}
	}
}
