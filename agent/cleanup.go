package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// CleanupItem is one thing that can be removed to free space.
// Safe items never touch running containers, volumes or app code.
type CleanupItem struct {
	ID       string   `json:"id"`
	Title    string   `json:"title"`
	Detail   string   `json:"detail"`
	Category string   `json:"category"` // safe, review
	Bytes    uint64   `json:"bytes"`
	Paths    []string `json:"paths,omitempty"`
	InUse    string   `json:"in_use,omitempty"` // why it can't be removed
}

type CleanupResult struct {
	ID    string `json:"id"`
	Freed uint64 `json:"freed_bytes"`
	Error string `json:"error,omitempty"`
}

// ---- helpers ----

func dirSize(ctx context.Context, p string) uint64 {
	out, err := exec.CommandContext(ctx, "du", "-s", "-x", "-B1", p).Output()
	if len(out) == 0 && err != nil {
		return 0
	}
	f := strings.Fields(string(out))
	if len(f) == 0 {
		return 0
	}
	var n uint64
	fmt.Sscan(f[0], &n)
	return n
}

func existingDirs(patterns ...string) []string {
	var out []string
	seen := map[string]bool{}
	for _, pat := range patterns {
		ms, _ := filepath.Glob(pat)
		for _, m := range ms {
			if fi, err := os.Stat(m); err == nil && fi.IsDir() && !seen[m] {
				seen[m] = true
				out = append(out, m)
			}
		}
	}
	return out
}

// removeContents empties a cache directory but keeps the directory itself.
func removeContents(dir string) error {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	var firstErr error
	for _, e := range ents {
		if err := os.RemoveAll(filepath.Join(dir, e.Name())); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func freeBytes(p string) uint64 {
	var st syscall.Statfs_t
	if syscall.Statfs(p, &st) != nil {
		return 0
	}
	return uint64(st.Bavail) * uint64(st.Bsize)
}

// cache directories of package managers, for root and every /home user
func cacheDirs() map[string][]string {
	homes := append([]string{"/root"}, existingDirs("/home/*")...)
	var composer, npm, yarn, pip, gob []string
	for _, h := range homes {
		composer = append(composer, existingDirs(h+"/.cache/composer", h+"/.composer/cache", h+"/.config/composer/cache")...)
		npm = append(npm, existingDirs(h+"/.npm/_cacache")...)
		yarn = append(yarn, existingDirs(h+"/.cache/yarn", h+"/.yarn/berry/cache")...)
		pip = append(pip, existingDirs(h+"/.cache/pip")...)
		gob = append(gob, existingDirs(h+"/.cache/go-build")...)
	}
	return map[string][]string{"composer": composer, "npm": npm, "yarn": yarn, "pip": pip, "go": gob}
}

func rotatedLogs() []string {
	var files []string
	_ = filepath.WalkDir("/var/log", func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		n := d.Name()
		if strings.HasSuffix(n, ".gz") || strings.HasSuffix(n, ".xz") || strings.HasSuffix(n, ".old") ||
			strings.HasSuffix(n, ".1") || isRotatedNumber(n) {
			files = append(files, p)
		}
		return nil
	})
	return files
}

// syslog.2, app.log.3 …
func isRotatedNumber(n string) bool {
	i := strings.LastIndexByte(n, '.')
	if i < 0 || i == len(n)-1 {
		return false
	}
	for _, c := range n[i+1:] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func filesSize(files []string) uint64 {
	var n uint64
	for _, f := range files {
		if fi, err := os.Lstat(f); err == nil && fi.Mode().IsRegular() {
			n += uint64(fi.Size())
		}
	}
	return n
}

// paths that must not be deleted: container mounts and working dirs of processes
func protectedPaths(ctx context.Context, d *DockerClient) []string {
	var out []string
	var list []struct {
		ID     string `json:"Id"`
		Mounts []struct {
			Source string `json:"Source"`
		} `json:"Mounts"`
	}
	if d.getJSON(ctx, "/containers/json?all=1", &list) == nil {
		for _, c := range list {
			for _, m := range c.Mounts {
				if m.Source != "" {
					out = append(out, filepath.Clean(m.Source))
				}
			}
		}
	}
	procs, _ := filepath.Glob("/proc/[0-9]*/cwd")
	for _, p := range procs {
		if t, err := os.Readlink(p); err == nil && t != "/" {
			out = append(out, filepath.Clean(t))
		}
	}
	return out
}

// usedBy reports a protected path that overlaps dir (inside it or containing it).
func usedBy(dir string, protected []string) string {
	for _, p := range protected {
		if p == dir || strings.HasPrefix(p, dir+"/") || strings.HasPrefix(dir, p+"/") {
			return p
		}
	}
	return ""
}

// vendor / node_modules folders in the usual app locations
func dependencyDirs(ctx context.Context) []string {
	var out []string
	for _, root := range []string{"/var/www", "/srv", "/opt", "/home", "/root"} {
		if _, err := os.Stat(root); err != nil {
			continue
		}
		cmd := exec.CommandContext(ctx, "find", root, "-xdev", "-maxdepth", "6", "-type", "d",
			"(", "-name", "vendor", "-o", "-name", "node_modules", ")", "-prune")
		b, _ := cmd.Output()
		for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
			l = strings.TrimSpace(l)
			if l == "" || strings.Contains(l, "/.cache/") || strings.Contains(l, "/.npm/") {
				continue
			}
			out = append(out, l)
		}
	}
	return out
}

// ---- scan ----

func (s *Server) CleanupScan(ctx context.Context) []CleanupItem {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	var items []CleanupItem
	add := func(it CleanupItem) {
		if it.Bytes > 0 {
			items = append(items, it)
		}
	}

	// Docker
	dd := s.docker.DiskUsage(ctx)
	if dd.Available {
		add(CleanupItem{ID: "docker-build-cache", Title: "Docker build cache", Category: "safe", Bytes: dd.BuildCache.Reclaimable,
			Detail: "Layers left over from image builds that nothing uses. The next build may take longer."})
		var dangling uint64
		for _, im := range dd.TopImages {
			if im.Name == "<none>" {
				dangling += im.Reclaimable
			}
		}
		add(CleanupItem{ID: "docker-dangling-images", Title: "Untagged Docker images", Category: "safe", Bytes: dangling,
			Detail: "Old <none> images replaced by newer builds or pulls. Not used by any container."})
		if unused := dd.Images.Reclaimable - min(dangling, dd.Images.Reclaimable); unused > 0 {
			add(CleanupItem{ID: "docker-unused-images", Title: "All unused Docker images", Category: "review", Bytes: unused,
				Detail: "Tagged images no container uses, also stopped ones keep theirs. They must be pulled or built again if you need them."})
		}
		var big uint64
		var bigFiles []string
		for _, l := range dd.TopLogs {
			if l.Bytes > 50<<20 {
				big += l.Bytes
				bigFiles = append(bigFiles, l.Name)
			}
		}
		add(CleanupItem{ID: "docker-logs", Title: "Large container logs", Category: "safe", Bytes: big, Paths: bigFiles,
			Detail: "Empties log files over 50 MB. Containers keep running; older log lines are gone. Tip: set log rotation (max-size) in daemon.json."})
	}

	// system
	if dirs := existingDirs("/var/cache/apt/archives"); len(dirs) > 0 {
		debs, _ := filepath.Glob("/var/cache/apt/archives/*.deb")
		add(CleanupItem{ID: "apt-cache", Title: "APT package cache", Category: "safe", Bytes: filesSize(debs),
			Detail: "Downloaded .deb files of installed updates (apt-get clean)."})
	}
	if out, err := runQuick(ctx, "journalctl", "--disk-usage"); err == nil {
		// "Archived and active journals take up 1.2G in the file system."
		if used := parseJournalUsage(out); used > 200<<20 {
			add(CleanupItem{ID: "journal", Title: "System journal", Category: "safe", Bytes: used - 200<<20,
				Detail: "Keeps the newest 200 MB of system logs, removes older ones (journalctl --vacuum-size)."})
		}
	}
	if rl := rotatedLogs(); len(rl) > 0 {
		add(CleanupItem{ID: "rotated-logs", Title: "Old rotated logs", Category: "safe", Bytes: filesSize(rl),
			Detail: fmt.Sprintf("%d archived log files in /var/log (.gz, .1, .old…). Current logs are kept.", len(rl))})
	}
	crash := existingDirs("/var/crash", "/var/lib/systemd/coredump")
	var crashSize uint64
	for _, d := range crash {
		crashSize += dirSize(ctx, d)
	}
	add(CleanupItem{ID: "crash-dumps", Title: "Crash dumps", Category: "safe", Bytes: crashSize, Paths: crash,
		Detail: "Memory dumps of programs that crashed."})

	// package-manager caches
	titles := map[string]string{"composer": "Composer cache", "npm": "npm cache", "yarn": "Yarn cache", "pip": "pip cache", "go": "Go build cache"}
	caches := cacheDirs()
	for _, k := range []string{"composer", "npm", "yarn", "pip", "go"} {
		dirs := caches[k]
		var n uint64
		for _, d := range dirs {
			n += dirSize(ctx, d)
		}
		add(CleanupItem{ID: "cache-" + k, Title: titles[k], Category: "safe", Bytes: n, Paths: dirs,
			Detail: "Download cache only; installed packages are untouched. Re-filled on the next install."})
	}

	// vendor / node_modules: only listed, never selected by default
	prot := protectedPaths(ctx, s.docker)
	for _, d := range dependencyDirs(ctx) {
		n := dirSize(ctx, d)
		if n < 20<<20 {
			continue
		}
		it := CleanupItem{ID: "dir:" + d, Title: filepath.Base(filepath.Dir(d)) + "/" + filepath.Base(d), Category: "review", Bytes: n, Paths: []string{d},
			Detail: "Installed dependencies. Delete only if this project is not deployed from here; restore with composer install / npm ci."}
		if u := usedBy(d, prot); u != "" {
			it.InUse = "in use: " + u
		}
		add(it)
	}

	sort.SliceStable(items, func(i, j int) bool {
		if items[i].Category != items[j].Category {
			return items[i].Category == "safe"
		}
		return items[i].Bytes > items[j].Bytes
	})
	if items == nil {
		items = []CleanupItem{}
	}
	return items
}

func parseJournalUsage(s string) uint64 {
	// "... take up 1.2G in the file system."
	i := strings.Index(s, "take up ")
	if i < 0 {
		return 0
	}
	f := strings.Fields(s[i+8:])
	if len(f) == 0 {
		return 0
	}
	v := f[0]
	mult := uint64(1)
	switch v[len(v)-1] {
	case 'K':
		mult = 1 << 10
	case 'M':
		mult = 1 << 20
	case 'G':
		mult = 1 << 30
	case 'T':
		mult = 1 << 40
	}
	if mult > 1 {
		v = v[:len(v)-1]
	}
	var x float64
	fmt.Sscan(v, &x)
	return uint64(x * float64(mult))
}

// ---- run ----

var cleanupMu sync.Mutex

// cleanupCancel stops a running cleanup after the item in progress.
var (
	cleanupCancelMu sync.Mutex
	cleanupCancel   context.CancelFunc
)

func cancelCleanup() bool {
	cleanupCancelMu.Lock()
	defer cleanupCancelMu.Unlock()
	if cleanupCancel == nil {
		return false
	}
	cleanupCancel()
	return true
}

func (s *Server) CleanupRun(ctx context.Context, ids []string) ([]CleanupResult, error) {
	if !cleanupMu.TryLock() {
		return nil, errors.New("a cleanup is already running")
	}
	defer cleanupMu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	stop, stopFn := context.WithCancel(context.Background())
	cleanupCancelMu.Lock()
	cleanupCancel = stopFn
	cleanupCancelMu.Unlock()
	defer func() {
		cleanupCancelMu.Lock()
		cleanupCancel = nil
		cleanupCancelMu.Unlock()
		stopFn()
	}()

	// re-scan: only items the agent itself offers can run, with fresh in-use checks
	offered := map[string]CleanupItem{}
	for _, it := range s.CleanupScan(ctx) {
		offered[it.ID] = it
	}
	var out []CleanupResult
	for _, id := range ids {
		if stop.Err() != nil {
			out = append(out, CleanupResult{ID: id, Error: "not run, stopped by user"})
			continue
		}
		it, ok := offered[id]
		if !ok {
			out = append(out, CleanupResult{ID: id, Error: "no longer applicable"})
			continue
		}
		if it.InUse != "" {
			out = append(out, CleanupResult{ID: id, Error: "skipped, " + it.InUse})
			continue
		}
		before := freeBytes("/")
		err := s.cleanOne(ctx, it)
		freed := freeBytes("/") - min(before, freeBytes("/"))
		if freed == 0 && err == nil {
			freed = it.Bytes // on another filesystem than /
		}
		r := CleanupResult{ID: id, Freed: freed}
		if err != nil {
			r.Error = err.Error()
		}
		log.Printf("cleanup %s: freed %s %v", id, humanBytes(freed), err)
		out = append(out, r)
	}
	return out, nil
}

func (s *Server) cleanOne(ctx context.Context, it CleanupItem) error {
	switch {
	case it.ID == "docker-build-cache":
		return s.docker.prune(ctx, "/build/prune")
	case it.ID == "docker-dangling-images":
		return s.docker.prune(ctx, "/images/prune?filters="+url.QueryEscape(`{"dangling":["true"]}`))
	case it.ID == "docker-unused-images":
		return s.docker.prune(ctx, "/images/prune?filters="+url.QueryEscape(`{"dangling":["false"]}`))
	case it.ID == "docker-logs":
		return s.docker.truncateLogs(ctx, 50<<20)
	case it.ID == "apt-cache":
		_, err := runQuick(ctx, "apt-get", "clean")
		return err
	case it.ID == "journal":
		_, err := runQuick(ctx, "journalctl", "--vacuum-size=200M")
		return err
	case it.ID == "rotated-logs":
		var first error
		for _, f := range rotatedLogs() {
			if err := os.Remove(f); err != nil && first == nil {
				first = err
			}
		}
		return first
	case it.ID == "crash-dumps" || strings.HasPrefix(it.ID, "cache-"):
		var first error
		for _, d := range it.Paths {
			if err := removeContents(d); err != nil && first == nil {
				first = err
			}
		}
		return first
	case strings.HasPrefix(it.ID, "dir:"):
		d := strings.TrimPrefix(it.ID, "dir:")
		b := filepath.Base(d)
		if b != "vendor" && b != "node_modules" {
			return errors.New("refusing to delete " + d)
		}
		return os.RemoveAll(d)
	}
	return errors.New("unknown item")
}

func (d *DockerClient) prune(ctx context.Context, path string) error {
	resp, err := d.do(ctx, http.MethodPost, path)
	if err != nil {
		return err
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return nil
}

// truncateLogs empties json-file logs above limit; Docker keeps appending to the same file.
func (d *DockerClient) truncateLogs(ctx context.Context, limit int64) error {
	var list []struct {
		ID string `json:"Id"`
	}
	if err := d.getJSON(ctx, "/containers/json?all=1", &list); err != nil {
		return err
	}
	var first error
	for _, c := range list {
		var ins struct {
			LogPath string `json:"LogPath"`
		}
		if d.getJSON(ctx, "/containers/"+c.ID+"/json", &ins) != nil || ins.LogPath == "" ||
			!strings.HasSuffix(ins.LogPath, "-json.log") {
			continue // only Docker's own json-file logs
		}
		if fi, err := os.Stat(ins.LogPath); err == nil && fi.Size() > limit {
			if err := os.Truncate(ins.LogPath, 0); err != nil && first == nil {
				first = err
			}
		}
	}
	return first
}

// ---- HTTP (admin over SSH only; the relay never forwards these) ----

func (s *Server) cleanupScan(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"items": s.CleanupScan(r.Context())})
}

func (s *Server) cleanupRun(w http.ResponseWriter, r *http.Request) {
	var in struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || len(in.IDs) == 0 {
		writeErr(w, 400, "ids required")
		return
	}
	res, err := s.CleanupRun(r.Context(), in.IDs)
	if err != nil {
		writeErr(w, 409, err.Error())
		return
	}
	var total uint64
	for _, x := range res {
		total += x.Freed
	}
	writeJSON(w, 200, map[string]any{"results": res, "freed_bytes": total})
}

func (s *Server) cleanupStop(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"stopping": cancelCleanup()})
}
