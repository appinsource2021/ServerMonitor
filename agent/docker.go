package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// DockerClient talks to the Docker Engine API over its unix socket. Read-only
// unless an action is explicitly invoked (and the config allows actions).
type DockerClient struct {
	http *http.Client
}

func NewDockerClient(sock string) *DockerClient {
	tr := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", sock)
		},
		MaxIdleConns:    16,
		IdleConnTimeout: 30 * time.Second,
	}
	return &DockerClient{http: &http.Client{Transport: tr, Timeout: 20 * time.Second}}
}

type DockerAPIError struct {
	Status  int
	Message string
}

func (e *DockerAPIError) Error() string { return fmt.Sprintf("docker %d: %s", e.Status, e.Message) }

func (d *DockerClient) do(ctx context.Context, method, path string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, "http://docker"+path, nil)
	if err != nil {
		return nil, err
	}
	resp, err := d.http.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 300 && resp.StatusCode != http.StatusNotModified {
		defer resp.Body.Close()
		var m struct {
			Message string `json:"message"`
		}
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		_ = json.Unmarshal(b, &m)
		if m.Message == "" {
			m.Message = strings.TrimSpace(string(b))
		}
		return nil, &DockerAPIError{Status: resp.StatusCode, Message: m.Message}
	}
	return resp, nil
}

func (d *DockerClient) getJSON(ctx context.Context, path string, v any) error {
	resp, err := d.do(ctx, http.MethodGet, path)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return json.NewDecoder(resp.Body).Decode(v)
}

type Container struct {
	ID             string   `json:"id"`
	Name           string   `json:"name"`
	Image          string   `json:"image"`
	State          string   `json:"state"`  // running, exited, restarting, paused, created, dead
	Status         string   `json:"status"` // human text from docker, e.g. "Up 3 days (healthy)"
	Health         string   `json:"health,omitempty"`
	ExitCode       int      `json:"exit_code"`
	OOMKilled      bool     `json:"oom_killed"`
	RestartCount   int      `json:"restart_count"`
	RestartPolicy  string   `json:"restart_policy"`
	StartedAt      string   `json:"started_at,omitempty"`
	FinishedAt     string   `json:"finished_at,omitempty"`
	CPUPercent     float64  `json:"cpu_percent"`
	MemBytes       uint64   `json:"mem_bytes"`
	MemLimitBytes  uint64   `json:"mem_limit_bytes"`
	ComposeProject string   `json:"compose_project,omitempty"`
	ComposeService string   `json:"compose_service,omitempty"`
	Ports          []string `json:"ports"`
	Ignored        bool     `json:"ignored,omitempty"`
	tty            bool
}

type listEntry struct {
	ID     string            `json:"Id"`
	Names  []string          `json:"Names"`
	Image  string            `json:"Image"`
	State  string            `json:"State"`
	Status string            `json:"Status"`
	Labels map[string]string `json:"Labels"`
	Ports  []struct {
		IP          string `json:"IP"`
		PrivatePort int    `json:"PrivatePort"`
		PublicPort  int    `json:"PublicPort"`
		Type        string `json:"Type"`
	} `json:"Ports"`
}

type inspectResult struct {
	RestartCount int `json:"RestartCount"`
	State        struct {
		OOMKilled  bool   `json:"OOMKilled"`
		ExitCode   int    `json:"ExitCode"`
		StartedAt  string `json:"StartedAt"`
		FinishedAt string `json:"FinishedAt"`
		Health     *struct {
			Status string `json:"Status"`
		} `json:"Health"`
	} `json:"State"`
	HostConfig struct {
		RestartPolicy struct {
			Name string `json:"Name"`
		} `json:"RestartPolicy"`
		Memory int64 `json:"Memory"`
	} `json:"HostConfig"`
	Config struct {
		Tty bool `json:"Tty"`
	} `json:"Config"`
}

type statsResult struct {
	CPUStats struct {
		CPUUsage struct {
			TotalUsage  uint64   `json:"total_usage"`
			PercpuUsage []uint64 `json:"percpu_usage"`
		} `json:"cpu_usage"`
		SystemCPUUsage uint64 `json:"system_cpu_usage"`
		OnlineCPUs     int    `json:"online_cpus"`
	} `json:"cpu_stats"`
	MemoryStats struct {
		Usage uint64            `json:"usage"`
		Limit uint64            `json:"limit"`
		Stats map[string]uint64 `json:"stats"`
	} `json:"memory_stats"`
}

type cpuSample struct {
	container uint64
	system    uint64
}

// DockerCollector keeps per-container CPU samples so CPU% is computed
// over the collection interval (one-shot stats have no precpu values).
type DockerCollector struct {
	client  *DockerClient
	mu      sync.Mutex
	prevCPU map[string]cpuSample
}

func NewDockerCollector(c *DockerClient) *DockerCollector {
	return &DockerCollector{client: c, prevCPU: map[string]cpuSample{}}
}

func (dc *DockerCollector) Collect(ctx context.Context) ([]Container, error) {
	var list []listEntry
	if err := dc.client.getJSON(ctx, "/containers/json?all=1", &list); err != nil {
		return nil, err
	}
	out := make([]Container, len(list))
	sem := make(chan struct{}, 8)
	var wg sync.WaitGroup
	for i := range list {
		out[i] = fromListEntry(list[i])
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			dc.enrich(ctx, list[i].ID, &out[i])
		}(i)
	}
	wg.Wait()

	seen := map[string]bool{}
	for _, c := range out {
		seen[c.ID] = true
	}
	dc.mu.Lock()
	for id := range dc.prevCPU {
		if !seen[id] {
			delete(dc.prevCPU, id)
		}
	}
	dc.mu.Unlock()

	sort.Slice(out, func(a, b int) bool {
		ra, rb := stateRank(out[a]), stateRank(out[b])
		if ra != rb {
			return ra < rb
		}
		return out[a].Name < out[b].Name
	})
	return out, nil
}

// stateRank puts problems first.
func stateRank(c Container) int {
	switch {
	case c.State == "dead" || (c.State == "exited" && c.ExitCode != 0):
		return 0
	case c.State == "restarting" || c.Health == "unhealthy":
		return 1
	case c.State == "running":
		return 2
	default:
		return 3
	}
}

func fromListEntry(e listEntry) Container {
	c := Container{
		ID:     shortID(e.ID),
		Image:  e.Image,
		State:  e.State,
		Status: e.Status,
		Ports:  []string{},
	}
	if len(e.Names) > 0 {
		c.Name = strings.TrimPrefix(e.Names[0], "/")
	}
	c.ComposeProject = e.Labels["com.docker.compose.project"]
	c.ComposeService = e.Labels["com.docker.compose.service"]
	c.Ignored = e.Labels["srvmon.ignore"] == "true"
	seen := map[string]bool{}
	for _, p := range e.Ports {
		var s string
		if p.PublicPort > 0 {
			s = fmt.Sprintf("%d→%d/%s", p.PublicPort, p.PrivatePort, p.Type)
		} else {
			s = fmt.Sprintf("%d/%s", p.PrivatePort, p.Type)
		}
		if !seen[s] {
			seen[s] = true
			c.Ports = append(c.Ports, s)
		}
	}
	return c
}

func (dc *DockerCollector) enrich(ctx context.Context, fullID string, c *Container) {
	var ins inspectResult
	if err := dc.client.getJSON(ctx, "/containers/"+fullID+"/json", &ins); err == nil {
		c.RestartCount = ins.RestartCount
		c.OOMKilled = ins.State.OOMKilled
		c.ExitCode = ins.State.ExitCode
		c.RestartPolicy = ins.HostConfig.RestartPolicy.Name
		c.tty = ins.Config.Tty
		if ins.State.Health != nil {
			c.Health = ins.State.Health.Status
		}
		if !strings.HasPrefix(ins.State.StartedAt, "0001-") {
			c.StartedAt = ins.State.StartedAt
		}
		if !strings.HasPrefix(ins.State.FinishedAt, "0001-") {
			c.FinishedAt = ins.State.FinishedAt
		}
		if ins.HostConfig.Memory > 0 {
			c.MemLimitBytes = uint64(ins.HostConfig.Memory)
		}
	}
	if c.State != "running" {
		dc.mu.Lock()
		delete(dc.prevCPU, c.ID)
		dc.mu.Unlock()
		return
	}
	var st statsResult
	if err := dc.client.getJSON(ctx, "/containers/"+fullID+"/stats?stream=false&one-shot=true", &st); err != nil {
		return
	}
	c.MemBytes = containerMemUsage(st)
	if c.MemLimitBytes == 0 && st.MemoryStats.Limit > 0 && st.MemoryStats.Limit < 1<<60 {
		c.MemLimitBytes = st.MemoryStats.Limit
	}
	cur := cpuSample{container: st.CPUStats.CPUUsage.TotalUsage, system: st.CPUStats.SystemCPUUsage}
	cpus := st.CPUStats.OnlineCPUs
	if cpus == 0 {
		cpus = len(st.CPUStats.CPUUsage.PercpuUsage)
	}
	dc.mu.Lock()
	prev, ok := dc.prevCPU[c.ID]
	dc.prevCPU[c.ID] = cur
	dc.mu.Unlock()
	if ok {
		c.CPUPercent = containerCPUPercent(prev, cur, cpus)
	}
}

// containerCPUPercent follows `docker stats`: can exceed 100 on multi-core.
func containerCPUPercent(prev, cur cpuSample, cpus int) float64 {
	if cur.container < prev.container || cur.system <= prev.system || cpus <= 0 {
		return 0
	}
	d := float64(cur.container - prev.container)
	s := float64(cur.system - prev.system)
	return round1(d / s * float64(cpus) * 100)
}

// containerMemUsage subtracts page cache like the docker CLI (v1 and v2 cgroups).
func containerMemUsage(st statsResult) uint64 {
	u := st.MemoryStats.Usage
	var cache uint64
	if v, ok := st.MemoryStats.Stats["inactive_file"]; ok {
		cache = v
	} else if v, ok := st.MemoryStats.Stats["total_inactive_file"]; ok {
		cache = v
	}
	if cache < u {
		return u - cache
	}
	return u
}

func shortID(id string) string {
	if len(id) > 12 {
		return id[:12]
	}
	return id
}

type LogLine struct {
	Time   string `json:"time,omitempty"`
	Stream string `json:"stream"`
	Text   string `json:"text"`
}

const maxLogBytes = 4 << 20

func (d *DockerClient) Logs(ctx context.Context, id string, tail int, since int64, tty bool) ([]LogLine, error) {
	q := url.Values{}
	q.Set("stdout", "1")
	q.Set("stderr", "1")
	q.Set("timestamps", "1")
	q.Set("tail", strconv.Itoa(tail))
	if since > 0 {
		q.Set("since", strconv.FormatInt(since, 10))
	}
	resp, err := d.do(ctx, http.MethodGet, "/containers/"+url.PathEscape(id)+"/logs?"+q.Encode())
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body := io.LimitReader(resp.Body, maxLogBytes)
	if tty || resp.Header.Get("Content-Type") == "application/vnd.docker.raw-stream" {
		return splitLogLines(body, "stdout"), nil
	}
	return demuxLogs(body)
}

// demuxLogs decodes Docker's multiplexed stream: 8-byte header
// [stream, 0, 0, 0, size(uint32 BE)] followed by size bytes.
func demuxLogs(r io.Reader) ([]LogLine, error) {
	var out []LogLine
	var partial [3]bytes.Buffer
	hdr := make([]byte, 8)
	for {
		if _, err := io.ReadFull(r, hdr); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				break
			}
			return out, err
		}
		stream := int(hdr[0])
		if stream > 2 {
			stream = 1
		}
		size := binary.BigEndian.Uint32(hdr[4:])
		frame := make([]byte, size)
		if _, err := io.ReadFull(r, frame); err != nil {
			break
		}
		buf := &partial[stream]
		buf.Write(frame)
		for {
			b := buf.Bytes()
			i := bytes.IndexByte(b, '\n')
			if i < 0 {
				break
			}
			out = append(out, parseLogLine(string(b[:i]), streamName(stream)))
			buf.Next(i + 1)
		}
	}
	for s := range partial {
		if partial[s].Len() > 0 {
			out = append(out, parseLogLine(partial[s].String(), streamName(s)))
		}
	}
	return out, nil
}

func splitLogLines(r io.Reader, stream string) []LogLine {
	var out []LogLine
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		out = append(out, parseLogLine(sc.Text(), stream))
	}
	return out
}

func streamName(s int) string {
	if s == 2 {
		return "stderr"
	}
	return "stdout"
}

// parseLogLine splits the RFC3339Nano timestamp docker prepends.
func parseLogLine(s, stream string) LogLine {
	s = strings.TrimRight(s, "\r")
	if ts, rest, ok := strings.Cut(s, " "); ok && len(ts) >= 20 && ts[4] == '-' && ts[10] == 'T' {
		return LogLine{Time: ts, Stream: stream, Text: rest}
	}
	return LogLine{Stream: stream, Text: s}
}

func (d *DockerClient) Action(ctx context.Context, id, action string) error {
	var path string
	switch action {
	case "start", "stop", "restart":
		path = "/containers/" + url.PathEscape(id) + "/" + action
		if action != "start" {
			path += "?t=10"
		}
	default:
		return fmt.Errorf("unknown action %q", action)
	}
	ctx, cancel := context.WithTimeout(ctx, 40*time.Second)
	defer cancel()
	resp, err := d.do(ctx, http.MethodPost, path)
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

// DockerInfo is the engine summary shown on the app's Docker card.
type DockerInfo struct {
	Version       string `json:"version"`
	Images        int    `json:"images"`
	StorageDriver string `json:"storage_driver,omitempty"`
	DataRoot      string `json:"data_root,omitempty"`
}

// Info reads GET /info. It is heavier than a container listing, so the
// collector asks for it only once a minute.
func (d *DockerClient) Info(ctx context.Context) (DockerInfo, error) {
	var raw struct {
		ServerVersion string `json:"ServerVersion"`
		Images        int    `json:"Images"`
		Driver        string `json:"Driver"`
		DockerRootDir string `json:"DockerRootDir"`
	}
	if err := d.getJSON(ctx, "/info", &raw); err != nil {
		return DockerInfo{}, err
	}
	return DockerInfo{Version: raw.ServerVersion, Images: raw.Images, StorageDriver: raw.Driver, DataRoot: raw.DockerRootDir}, nil
}

// dockerLoad sums what the running containers use: CPU as a share of the whole
// host (0-100, like the host figure) and memory in bytes.
func dockerLoad(containers []Container, cpus int) (cpu float64, mem uint64) {
	for _, c := range containers {
		if c.State != "running" {
			continue
		}
		cpu += c.CPUPercent
		mem += c.MemBytes
	}
	if cpus > 0 {
		cpu /= float64(cpus)
	}
	if cpu > 100 {
		cpu = 100
	}
	return round1(cpu), mem
}
