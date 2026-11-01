package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// ---- folder scan (du + largest files), runs in the background ----

type DiskEntry struct {
	Path  string `json:"path"`
	Name  string `json:"name"`
	Bytes uint64 `json:"bytes"`
}

type DiskScan struct {
	Path       string      `json:"path"`
	Status     string      `json:"status"` // running, done, error
	Error      string      `json:"error,omitempty"`
	StartedAt  time.Time   `json:"started_at"`
	FinishedAt *time.Time  `json:"finished_at,omitempty"`
	Total      uint64      `json:"total_bytes"`
	Entries    []DiskEntry `json:"entries"`       // direct children, biggest first
	Largest    []DiskEntry `json:"largest_files"` // biggest files under path (same filesystem)
}

type diskScanner struct {
	mu      sync.Mutex
	scans   map[string]*DiskScan
	cancels map[string]context.CancelFunc
}

var scanner = &diskScanner{scans: map[string]*DiskScan{}, cancels: map[string]context.CancelFunc{}}

const scanTTL = 10 * time.Minute

func cleanScanPath(p string) (string, error) {
	if p == "" {
		p = "/"
	}
	if !filepath.IsAbs(p) || strings.Contains(p, "\x00") {
		return "", errors.New("path must be absolute")
	}
	p = filepath.Clean(p)
	fi, err := os.Stat(p)
	if err != nil {
		return "", err
	}
	if !fi.IsDir() {
		return "", errors.New("not a directory")
	}
	return p, nil
}

// Start begins a scan unless a fresh or running one exists (force re-scans).
func (d *diskScanner) Start(p string, force bool) *DiskScan {
	d.mu.Lock()
	defer d.mu.Unlock()
	if s, ok := d.scans[p]; ok {
		fresh := s.FinishedAt != nil && time.Since(*s.FinishedAt) < scanTTL
		if s.Status == "running" || (fresh && !force) {
			c := *s
			return &c
		}
	}
	s := &DiskScan{Path: p, Status: "running", StartedAt: time.Now(), Entries: []DiskEntry{}, Largest: []DiskEntry{}}
	d.scans[p] = s
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	d.cancels[p] = cancel
	go d.run(ctx, s)
	c := *s
	return &c
}

func (d *diskScanner) Get(p string) (*DiskScan, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	s, ok := d.scans[p]
	if !ok {
		return nil, false
	}
	c := *s
	return &c, true
}

// Cancel stops a running scan; du/find are killed with the context.
func (d *diskScanner) Cancel(p string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	s, ok := d.scans[p]
	if !ok || s.Status != "running" {
		return false
	}
	if c := d.cancels[p]; c != nil {
		c()
	}
	now := time.Now()
	s.Status, s.Error, s.FinishedAt = "cancelled", "stopped by user", &now
	return true
}

func (d *diskScanner) run(ctx context.Context, s *DiskScan) {
	defer func() {
		d.mu.Lock()
		if c := d.cancels[s.Path]; c != nil {
			c()
			delete(d.cancels, s.Path)
		}
		d.mu.Unlock()
	}()
	entries, total, err := duChildren(ctx, s.Path)
	var largest []DiskEntry
	if err == nil {
		largest, _ = largestFiles(ctx, s.Path, 25)
	}
	now := time.Now()
	d.mu.Lock()
	defer d.mu.Unlock()
	if s.Status == "cancelled" || ctx.Err() == context.Canceled {
		s.Status = "cancelled"
		return
	}
	s.FinishedAt = &now
	if ctx.Err() == context.DeadlineExceeded {
		s.Status, s.Error = "error", "the scan took longer than 15 minutes and was stopped; scan a smaller folder"
		return
	}
	if err != nil {
		s.Status, s.Error = "error", err.Error()
		return
	}
	s.Status, s.Total, s.Entries = "done", total, entries
	if largest != nil {
		s.Largest = largest
	}
}

// killableCmd runs in its own process group; cancelling the context kills the whole
// group (nice, ionice, du/find) and Output() returns at most 3 s later even if a
// child still holds the pipe.
func killableCmd(ctx context.Context, name string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = 3 * time.Second
	return cmd
}

// duChildren: `du -x -B1 -d1 path` — stays on one filesystem, sizes in bytes.
func duChildren(ctx context.Context, p string) ([]DiskEntry, uint64, error) {
	out, err := killableCmd(ctx, "nice", "-n", "15", "ionice", "-c3", "du", "-x", "-B1", "-d1", p).Output()
	if len(out) == 0 && err != nil && ctx.Err() == nil {
		// ionice may be missing: retry without it
		out, err = killableCmd(ctx, "nice", "-n", "15", "du", "-x", "-B1", "-d1", p).Output()
	}
	if len(out) == 0 {
		if err == nil {
			err = errors.New("du returned nothing")
		}
		return nil, 0, err
	}
	// du exits 1 on unreadable files; partial output is still useful
	entries, total := parseDu(string(out), p)
	return entries, total, nil
}

func parseDu(out, root string) ([]DiskEntry, uint64) {
	var entries []DiskEntry
	var total uint64
	sc := bufio.NewScanner(strings.NewReader(out))
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		size, path, ok := strings.Cut(sc.Text(), "\t")
		if !ok {
			continue
		}
		n, err := strconv.ParseUint(strings.TrimSpace(size), 10, 64)
		if err != nil {
			continue
		}
		if filepath.Clean(path) == filepath.Clean(root) {
			total = n
			continue
		}
		entries = append(entries, DiskEntry{Path: path, Name: filepath.Base(path), Bytes: n})
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Bytes > entries[j].Bytes })
	if entries == nil {
		entries = []DiskEntry{}
	}
	return entries, total
}

// largestFiles: biggest regular files over 50 MB on the same filesystem.
func largestFiles(ctx context.Context, p string, n int) ([]DiskEntry, error) {
	out, err := killableCmd(ctx, "nice", "-n", "15", "find", p, "-xdev", "-type", "f", "-size", "+50M", "-printf", "%s\t%p\n").Output()
	if len(out) == 0 && err != nil {
		return nil, err
	}
	files := parseFind(string(out))
	if len(files) > n {
		files = files[:n]
	}
	return files, nil
}

func parseFind(out string) []DiskEntry {
	files := []DiskEntry{}
	sc := bufio.NewScanner(strings.NewReader(out))
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		size, path, ok := strings.Cut(sc.Text(), "\t")
		if !ok {
			continue
		}
		b, err := strconv.ParseUint(size, 10, 64)
		if err != nil {
			continue
		}
		files = append(files, DiskEntry{Path: path, Name: filepath.Base(path), Bytes: b})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Bytes > files[j].Bytes })
	return files
}

// ---- Docker's share of the disk ----

type DockerDiskItem struct {
	Name        string `json:"name"`
	Bytes       uint64 `json:"bytes"`
	Reclaimable uint64 `json:"reclaimable_bytes"`
	Detail      string `json:"detail,omitempty"`
}

type DockerDisk struct {
	Available   bool             `json:"available"`
	Error       string           `json:"error,omitempty"`
	Images      DockerDiskItem   `json:"images"`
	Containers  DockerDiskItem   `json:"containers"`
	Volumes     DockerDiskItem   `json:"volumes"`
	BuildCache  DockerDiskItem   `json:"build_cache"`
	Logs        DockerDiskItem   `json:"logs"`
	TopImages   []DockerDiskItem `json:"top_images"`
	TopVolumes  []DockerDiskItem `json:"top_volumes"`
	TopLogs     []DockerDiskItem `json:"top_logs"`
	DataRoot    string           `json:"data_root,omitempty"`
	TotalBytes  uint64           `json:"total_bytes"`
	Reclaimable uint64           `json:"reclaimable_bytes"`
}

type systemDF struct {
	LayersSize int64 `json:"LayersSize"`
	Images     []struct {
		RepoTags   []string `json:"RepoTags"`
		Size       int64    `json:"Size"`
		SharedSize int64    `json:"SharedSize"`
		Containers int64    `json:"Containers"`
	} `json:"Images"`
	Containers []struct {
		Names  []string `json:"Names"`
		SizeRw int64    `json:"SizeRw"`
		State  string   `json:"State"`
	} `json:"Containers"`
	Volumes []struct {
		Name      string `json:"Name"`
		UsageData *struct {
			Size     int64 `json:"Size"`
			RefCount int64 `json:"RefCount"`
		} `json:"UsageData"`
	} `json:"Volumes"`
	BuildCache []struct {
		Size   int64 `json:"Size"`
		InUse  bool  `json:"InUse"`
		Shared bool  `json:"Shared"`
	} `json:"BuildCache"`
}

func pos(v int64) uint64 {
	if v < 0 {
		return 0
	}
	return uint64(v)
}

func (d *DockerClient) DiskUsage(ctx context.Context) DockerDisk {
	out := DockerDisk{TopImages: []DockerDiskItem{}, TopVolumes: []DockerDiskItem{}, TopLogs: []DockerDiskItem{}}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	var df systemDF
	if err := d.getJSON(ctx, "/system/df", &df); err != nil {
		out.Error = err.Error()
		return out
	}
	out.Available = true
	var info struct {
		DockerRootDir string `json:"DockerRootDir"`
	}
	if d.getJSON(ctx, "/info", &info) == nil {
		out.DataRoot = info.DockerRootDir
	}

	// images: unique size = Size - SharedSize; unused images are reclaimable
	out.Images.Name = "Images"
	var unused int
	for _, im := range df.Images {
		uniq := pos(im.Size - im.SharedSize)
		if im.SharedSize < 0 {
			uniq = pos(im.Size)
		}
		out.Images.Bytes += uniq
		name := "<none>"
		if len(im.RepoTags) > 0 && im.RepoTags[0] != "<none>:<none>" {
			name = im.RepoTags[0]
		}
		item := DockerDiskItem{Name: name, Bytes: pos(im.Size)}
		if im.Containers == 0 {
			out.Images.Reclaimable += uniq
			item.Reclaimable = uniq
			unused++
		}
		out.TopImages = append(out.TopImages, item)
	}
	if df.LayersSize > 0 {
		// the engine's own total counts shared layers once
		out.Images.Bytes = pos(df.LayersSize)
	} else if len(df.Images) > 0 {
		out.Images.Bytes += pos(df.Images[0].SharedSize)
	}
	out.Images.Detail = strconv.Itoa(len(df.Images)) + " images, " + strconv.Itoa(unused) + " unused"

	out.Containers.Name = "Container layers"
	stopped := 0
	for _, c := range df.Containers {
		out.Containers.Bytes += pos(c.SizeRw)
		if c.State != "running" {
			out.Containers.Reclaimable += pos(c.SizeRw)
			stopped++
		}
	}
	out.Containers.Detail = strconv.Itoa(len(df.Containers)) + " containers, " + strconv.Itoa(stopped) + " stopped"

	out.Volumes.Name = "Volumes"
	unusedVol := 0
	for _, v := range df.Volumes {
		if v.UsageData == nil {
			continue
		}
		sz := pos(v.UsageData.Size)
		out.Volumes.Bytes += sz
		item := DockerDiskItem{Name: v.Name, Bytes: sz}
		if v.UsageData.RefCount == 0 {
			out.Volumes.Reclaimable += sz
			item.Reclaimable = sz
			unusedVol++
		}
		out.TopVolumes = append(out.TopVolumes, item)
	}
	out.Volumes.Detail = strconv.Itoa(len(df.Volumes)) + " volumes, " + strconv.Itoa(unusedVol) + " unused"

	out.BuildCache.Name = "Build cache"
	for _, b := range df.BuildCache {
		if b.Shared {
			continue
		}
		out.BuildCache.Bytes += pos(b.Size)
		if !b.InUse {
			out.BuildCache.Reclaimable += pos(b.Size)
		}
	}
	out.BuildCache.Detail = strconv.Itoa(len(df.BuildCache)) + " entries"

	// container log files (json-file driver) live outside the layers
	out.Logs.Name = "Container logs"
	var list []struct {
		ID    string   `json:"Id"`
		Names []string `json:"Names"`
	}
	if d.getJSON(ctx, "/containers/json?all=1", &list) == nil {
		for _, c := range list {
			var ins struct {
				LogPath string `json:"LogPath"`
			}
			if d.getJSON(ctx, "/containers/"+c.ID+"/json", &ins) != nil || ins.LogPath == "" {
				continue
			}
			fi, err := os.Stat(ins.LogPath)
			if err != nil {
				continue
			}
			name := c.ID[:12]
			if len(c.Names) > 0 {
				name = strings.TrimPrefix(c.Names[0], "/")
			}
			sz := uint64(fi.Size())
			out.Logs.Bytes += sz
			out.TopLogs = append(out.TopLogs, DockerDiskItem{Name: name, Bytes: sz})
		}
	}
	out.Logs.Detail = "json-file logs, no size limit unless set"

	for _, s := range []*[]DockerDiskItem{&out.TopImages, &out.TopVolumes, &out.TopLogs} {
		sort.Slice(*s, func(i, j int) bool { return (*s)[i].Bytes > (*s)[j].Bytes })
		if len(*s) > 15 {
			*s = (*s)[:15]
		}
	}
	for _, it := range []DockerDiskItem{out.Images, out.Containers, out.Volumes, out.BuildCache, out.Logs} {
		out.TotalBytes += it.Bytes
		out.Reclaimable += it.Reclaimable
	}
	return out
}

// ---- HTTP ----

func (s *Server) diskScanStart(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Path  string `json:"path"`
		Force bool   `json:"force"`
	}
	if r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			writeErr(w, 400, err.Error())
			return
		}
	}
	p, err := cleanScanPath(in.Path)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, scanner.Start(p, in.Force))
}

func (s *Server) diskScanGet(w http.ResponseWriter, r *http.Request) {
	p, err := cleanScanPath(r.URL.Query().Get("path"))
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	sc, ok := scanner.Get(p)
	if !ok {
		writeErr(w, 404, "no scan for this path yet")
		return
	}
	writeJSON(w, 200, sc)
}

func (s *Server) diskDocker(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, s.docker.DiskUsage(r.Context()))
}

func (s *Server) diskScanCancel(w http.ResponseWriter, r *http.Request) {
	p, err := cleanScanPath(r.URL.Query().Get("path"))
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"cancelled": scanner.Cancel(p)})
}
