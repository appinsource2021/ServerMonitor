package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

// ---- file manager: list, read, write, delete ----
//
// Admin over SSH only. HandleMember never routes /v1/fs, so relay members
// always get 403. Every change is guarded by a deny list, a backup and an
// atomic write; deletes refuse mount points and (without force) paths that a
// container mounts or a process works in.

const (
	fsMaxList = 2000      // entries per listing
	fsMaxRead = 512 << 10 // bigger text files come back as a tail
	fsMaxEdit = 64 << 10  // a write travels as one SSH command-line argument
	fsMaxBody = 256 << 10 // request body limit for /v1/fs/write
	fsKeepBak = 3         // backups kept per file
)

// Never written or deleted, subtrees included. Top-level directories (/var,
// /etc, /home …) and /var/lib/docker are refused for delete as well.
var fsDeny = []string{"/", "/proc", "/sys", "/dev", "/boot", "/usr", "/bin", "/sbin",
	"/lib", "/lib32", "/lib64", "/libx32", "/etc/srvmon", "/usr/local/bin/srvmon-agent", "/run/srvmon"}

// Not even listed or read: nothing useful there and some entries block or are huge.
var fsNoRead = []string{"/proc", "/sys", "/dev"}

type FSEntry struct {
	Name   string    `json:"name"`
	Path   string    `json:"path"`
	Type   string    `json:"type"` // dir, file, symlink, other
	Bytes  uint64    `json:"bytes"`
	MTime  time.Time `json:"mtime"`
	Mode   string    `json:"mode"`
	Owner  string    `json:"owner"`
	Group  string    `json:"group"`
	Target string    `json:"target,omitempty"` // symlink target
	InUse  string    `json:"in_use,omitempty"` // why deleting it is risky
}

type FSListing struct {
	Path      string    `json:"path"`
	Parent    string    `json:"parent,omitempty"`
	Entries   []FSEntry `json:"entries"`
	Truncated bool      `json:"truncated"`
	Protected string    `json:"protected,omitempty"` // this directory itself may not be changed
	InUse     string    `json:"in_use,omitempty"`
}

type FSFile struct {
	Path      string    `json:"path"`
	Bytes     uint64    `json:"bytes"`
	MTime     time.Time `json:"mtime"`
	Mode      string    `json:"mode"`
	Owner     string    `json:"owner"`
	Group     string    `json:"group"`
	SHA256    string    `json:"sha256,omitempty"` // only when editable
	Content   string    `json:"content"`
	Truncated bool      `json:"truncated"` // only the tail is included
	Binary    bool      `json:"binary"`    // content omitted
	Editable  bool      `json:"editable"`
	Protected string    `json:"protected,omitempty"`
	InUse     string    `json:"in_use,omitempty"`
}

func fsCleanPath(p string) (string, error) {
	if p == "" || !filepath.IsAbs(p) || strings.Contains(p, "\x00") {
		return "", errors.New("path must be absolute")
	}
	return filepath.Clean(p), nil
}

func fsUnder(p string, roots []string) string {
	for _, d := range roots {
		if p == d || (d != "/" && strings.HasPrefix(p, d+"/")) {
			return d
		}
	}
	return ""
}

func fsUnreadable(p string) bool { return fsUnder(p, fsNoRead) != "" }

// fsProtected reports why p may not be written or deleted: p, an ancestor, or
// the symlink-resolved path is on the deny list. "" means allowed.
func fsProtected(p string) string {
	if d := fsUnder(p, fsDeny); d != "" {
		return d
	}
	// a symlink into a protected tree is not a side door
	if real, err := filepath.EvalSymlinks(p); err == nil {
		if d := fsUnder(real, fsDeny); d != "" {
			return d
		}
	} else if real, err := filepath.EvalSymlinks(filepath.Dir(p)); err == nil {
		if d := fsUnder(filepath.Join(real, filepath.Base(p)), fsDeny); d != "" {
			return d
		}
	}
	return ""
}

// fsUndeletable adds the delete-only rules to fsProtected.
func fsUndeletable(p string) string {
	if d := fsProtected(p); d != "" {
		return d
	}
	if strings.Count(p, "/") == 1 { // /var, /etc, /home …
		return "top-level directory"
	}
	if d := fsUnder(p, []string{"/var/lib/docker"}); d != "" {
		return d + " (use Smart cleanup)"
	}
	return ""
}

// fsInUse maps paths to why deleting them is risky: bind mounts of containers
// and working directories of running processes (same idea as protectedPaths in
// cleanup.go, with a reason per path).
func fsInUse(ctx context.Context, d *DockerClient) map[string]string {
	out := map[string]string{}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var list []struct {
		Names  []string `json:"Names"`
		State  string   `json:"State"`
		Mounts []struct {
			Source string `json:"Source"`
		} `json:"Mounts"`
	}
	if d != nil && d.getJSON(ctx, "/containers/json?all=1", &list) == nil {
		for _, c := range list {
			name := "a container"
			if len(c.Names) > 0 {
				name = "container " + strings.TrimPrefix(c.Names[0], "/")
			}
			if c.State != "running" {
				name += " (stopped)"
			}
			for _, m := range c.Mounts {
				if m.Source != "" {
					out[filepath.Clean(m.Source)] = "mounted into " + name
				}
			}
		}
	}
	procs, _ := filepath.Glob("/proc/[0-9]*/cwd")
	for _, p := range procs {
		t, err := os.Readlink(p)
		if err != nil || t == "/" {
			continue
		}
		t = filepath.Clean(t)
		if _, ok := out[t]; ok {
			continue
		}
		comm, _ := os.ReadFile(filepath.Join(filepath.Dir(p), "comm"))
		name := strings.TrimSpace(string(comm))
		if name == "" {
			name = "pid " + filepath.Base(filepath.Dir(p))
		}
		out[t] = "working directory of " + name
	}
	return out
}

// fsUsedBy: p is in use when it is, contains, or sits inside an in-use path.
func fsUsedBy(p string, inUse map[string]string) string {
	for q, why := range inUse {
		if q == p || strings.HasPrefix(q, p+"/") || strings.HasPrefix(p, q+"/") {
			return why
		}
	}
	return ""
}

type idNames struct {
	users, groups map[uint32]string
}

func newIDNames() *idNames { return &idNames{users: map[uint32]string{}, groups: map[uint32]string{}} }

func (n *idNames) owner(st *syscall.Stat_t) (string, string) {
	if st == nil {
		return "", ""
	}
	u, ok := n.users[st.Uid]
	if !ok {
		u = strconv.FormatUint(uint64(st.Uid), 10)
		if x, err := user.LookupId(u); err == nil {
			u = x.Username
		}
		n.users[st.Uid] = u
	}
	g, ok := n.groups[st.Gid]
	if !ok {
		g = strconv.FormatUint(uint64(st.Gid), 10)
		if x, err := user.LookupGroupId(g); err == nil {
			g = x.Name
		}
		n.groups[st.Gid] = g
	}
	return u, g
}

func statT(fi os.FileInfo) *syscall.Stat_t {
	st, _ := fi.Sys().(*syscall.Stat_t)
	return st
}

func fsEntry(p string, fi os.FileInfo, names *idNames) FSEntry {
	e := FSEntry{Name: filepath.Base(p), Path: p, MTime: fi.ModTime(), Mode: fi.Mode().String()}
	e.Owner, e.Group = names.owner(statT(fi))
	switch {
	case fi.IsDir():
		e.Type = "dir"
	case fi.Mode()&os.ModeSymlink != 0:
		e.Target, _ = os.Readlink(p)
		// a link to a folder browses like a folder; delete still removes only the link
		if tfi, err := os.Stat(p); err == nil && tfi.IsDir() {
			e.Type = "dir"
		} else {
			e.Type = "symlink"
			if err == nil && tfi.Mode().IsRegular() {
				e.Bytes = uint64(tfi.Size())
			}
		}
	case fi.Mode().IsRegular():
		e.Type = "file"
		e.Bytes = uint64(fi.Size())
	default:
		e.Type = "other"
	}
	return e
}

func fsIsBinary(b []byte) bool {
	head := b
	if len(head) > 8<<10 {
		head = head[:8<<10]
	}
	return bytes.IndexByte(head, 0) >= 0 || !utf8.Valid(b)
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// fsReadFile returns the whole file, or its tail after the first newline when
// it is bigger than fsMaxRead.
func fsReadFile(p string, size int64) ([]byte, bool, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, false, err
	}
	defer f.Close()
	if size <= fsMaxRead {
		b, err := io.ReadAll(io.LimitReader(f, fsMaxRead+1))
		if err != nil {
			return nil, false, err
		}
		if len(b) <= fsMaxRead { // the file did not grow past the cap meanwhile
			return b, false, nil
		}
		size = int64(len(b))
	}
	if _, err := f.Seek(size-fsMaxRead, io.SeekStart); err != nil {
		return nil, false, err
	}
	b, err := io.ReadAll(io.LimitReader(f, fsMaxRead))
	if err != nil {
		return nil, false, err
	}
	if i := bytes.IndexByte(b, '\n'); i >= 0 && i+1 < len(b) {
		b = b[i+1:]
	}
	return b, true, nil
}

// fsAtomicWrite puts data in place via a temp file in the same directory, so a
// crash never leaves a half-written file; mode and owner are preserved.
func fsAtomicWrite(target string, data []byte, mode os.FileMode, st *syscall.Stat_t) error {
	dir := filepath.Dir(target)
	tmp, err := os.CreateTemp(dir, ".srvmon-tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if st != nil {
		if err := tmp.Chown(int(st.Uid), int(st.Gid)); err != nil && os.Geteuid() == 0 {
			tmp.Close()
			return err
		}
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), target)
}

// fsBackup copies target to target.srvmon-bak-<ts> and keeps only the newest fsKeepBak.
func fsBackup(target string, data []byte, mode os.FileMode) (string, error) {
	base := target + ".srvmon-bak-"
	ts := time.Now().Format("20060102-150405")
	bak := base + ts
	for i := 1; ; i++ {
		if _, err := os.Lstat(bak); err != nil {
			break
		}
		bak = base + ts + "-" + strconv.Itoa(i)
	}
	if err := os.WriteFile(bak, data, mode.Perm()); err != nil {
		return "", err
	}
	old, _ := filepath.Glob(base + "*")
	sort.Strings(old)
	for len(old) > fsKeepBak {
		_ = os.Remove(old[0])
		old = old[1:]
	}
	return bak, nil
}

// ---- HTTP ----

func fsParam(r *http.Request) (string, bool, error) {
	p, err := fsCleanPath(r.URL.Query().Get("path"))
	if err != nil {
		return "", false, err
	}
	f := r.URL.Query().Get("force")
	return p, f == "1" || f == "true", nil
}

func (s *Server) fsList(w http.ResponseWriter, r *http.Request) {
	p, _, err := fsParam(r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if fsUnreadable(p) {
		writeErr(w, 403, p+" is not browsable")
		return
	}
	fi, err := os.Stat(p)
	if err != nil {
		writeErr(w, 404, err.Error())
		return
	}
	if !fi.IsDir() {
		writeErr(w, 400, "not a directory")
		return
	}
	des, err := os.ReadDir(p)
	if err != nil {
		writeErr(w, 403, err.Error())
		return
	}
	inUse := fsInUse(r.Context(), s.docker)
	names := newIDNames()
	out := FSListing{Path: p, Entries: []FSEntry{}, Protected: fsUndeletable(p), InUse: fsUsedBy(p, inUse)}
	if p != "/" {
		out.Parent = filepath.Dir(p)
	}
	sort.Slice(des, func(i, j int) bool {
		if des[i].IsDir() != des[j].IsDir() {
			return des[i].IsDir()
		}
		return strings.ToLower(des[i].Name()) < strings.ToLower(des[j].Name())
	})
	for _, de := range des {
		if len(out.Entries) >= fsMaxList {
			out.Truncated = true
			break
		}
		fi, err := de.Info()
		if err != nil {
			continue
		}
		e := fsEntry(filepath.Join(p, de.Name()), fi, names)
		e.InUse = fsUsedBy(e.Path, inUse)
		out.Entries = append(out.Entries, e)
	}
	writeJSON(w, 200, out)
}

func (s *Server) fsRead(w http.ResponseWriter, r *http.Request) {
	p, _, err := fsParam(r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if fsUnreadable(p) {
		writeErr(w, 403, p+" is not readable")
		return
	}
	fi, err := os.Stat(p)
	if err != nil {
		writeErr(w, 404, err.Error())
		return
	}
	if !fi.Mode().IsRegular() {
		writeErr(w, 400, "not a regular file")
		return
	}
	data, truncated, err := fsReadFile(p, fi.Size())
	if err != nil {
		writeErr(w, 403, err.Error())
		return
	}
	out := FSFile{Path: p, Bytes: uint64(fi.Size()), MTime: fi.ModTime(), Mode: fi.Mode().String(),
		Truncated: truncated, Protected: fsProtected(p), InUse: fsUsedBy(p, fsInUse(r.Context(), s.docker))}
	out.Owner, out.Group = newIDNames().owner(statT(fi))
	if fsIsBinary(data) {
		out.Binary = true
	} else {
		out.Content = string(data)
	}
	if !truncated && !out.Binary && len(data) <= fsMaxEdit {
		out.Editable = out.Protected == ""
		out.SHA256 = sha256Hex(data)
	}
	writeJSON(w, 200, out)
}

func (s *Server) fsWrite(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Path         string `json:"path"`
		Content      string `json:"content"`
		ExpectSHA256 string `json:"expect_sha256"`
		Create       bool   `json:"create"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	p, err := fsCleanPath(in.Path)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if d := fsProtected(p); d != "" {
		writeErr(w, 403, "protected path ("+d+")")
		return
	}
	if len(in.Content) > fsMaxEdit {
		writeErr(w, 413, "files over "+strconv.Itoa(fsMaxEdit>>10)+" KB cannot be edited from the app")
		return
	}
	data := []byte(in.Content)
	target := p
	fi, err := os.Lstat(p)
	switch {
	case err == nil:
		if fi.Mode()&os.ModeSymlink != 0 {
			// write through the link, never replace it with a plain file
			if target, err = filepath.EvalSymlinks(p); err != nil {
				writeErr(w, 400, err.Error())
				return
			}
			if fi, err = os.Stat(target); err != nil {
				writeErr(w, 400, err.Error())
				return
			}
		}
		if !fi.Mode().IsRegular() {
			writeErr(w, 400, "not a regular file")
			return
		}
		if fi.Size() > fsMaxRead {
			writeErr(w, 413, "the file on the server is too big to edit from the app")
			return
		}
		cur, err := os.ReadFile(target)
		if err != nil {
			writeErr(w, 403, err.Error())
			return
		}
		curSum := sha256Hex(cur)
		if in.ExpectSHA256 == "" {
			writeErr(w, 400, "expect_sha256 is required when the file exists")
			return
		}
		if curSum != in.ExpectSHA256 {
			writeJSON(w, 409, map[string]any{"error": "the file changed on the server since you opened it",
				"sha256": curSum, "mtime": fi.ModTime(), "bytes": fi.Size()})
			return
		}
		bak, err := fsBackup(target, cur, fi.Mode())
		if err != nil {
			writeErr(w, 500, "backup failed: "+err.Error())
			return
		}
		if err := fsAtomicWrite(target, data, fi.Mode().Perm(), statT(fi)); err != nil {
			writeErr(w, 500, err.Error())
			return
		}
		nfi, _ := os.Stat(target)
		var mt time.Time
		if nfi != nil {
			mt = nfi.ModTime()
		}
		writeJSON(w, 200, map[string]any{"path": p, "bytes": len(data), "mtime": mt, "sha256": sha256Hex(data), "backup": bak})
	case os.IsNotExist(err):
		if !in.Create {
			writeErr(w, 404, "file does not exist")
			return
		}
		if dfi, err := os.Stat(filepath.Dir(p)); err != nil || !dfi.IsDir() {
			writeErr(w, 400, "parent directory does not exist")
			return
		}
		if err := fsAtomicWrite(p, data, 0o644, nil); err != nil {
			writeErr(w, 500, err.Error())
			return
		}
		nfi, _ := os.Stat(p)
		var mt time.Time
		if nfi != nil {
			mt = nfi.ModTime()
		}
		writeJSON(w, 200, map[string]any{"path": p, "bytes": len(data), "mtime": mt, "sha256": sha256Hex(data), "created": true})
	default:
		writeErr(w, 400, err.Error())
	}
}

// fsTreeSize walks dir without following symlinks: total bytes, entry count, and
// the first directory that lives on another filesystem (a mount point).
func fsTreeSize(ctx context.Context, dir string, dev uint64) (uint64, int, string, error) {
	var total uint64
	var count int
	mount := ""
	err := filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			return nil // unreadable entries still get removed by RemoveAll
		}
		count++
		fi, err := d.Info()
		if err != nil {
			return nil
		}
		if d.IsDir() && p != dir {
			if st := statT(fi); st != nil && uint64(st.Dev) != dev {
				mount = p
				return filepath.SkipAll
			}
		}
		if fi.Mode().IsRegular() {
			total += uint64(fi.Size())
		}
		return nil
	})
	return total, count, mount, err
}

func (s *Server) fsDelete(w http.ResponseWriter, r *http.Request) {
	p, force, err := fsParam(r)
	if err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if d := fsUndeletable(p); d != "" {
		writeErr(w, 403, "protected path ("+d+")")
		return
	}
	fi, err := os.Lstat(p)
	if err != nil {
		writeErr(w, 404, err.Error())
		return
	}
	if why := fsUsedBy(p, fsInUse(r.Context(), s.docker)); why != "" && !force {
		writeJSON(w, 409, map[string]any{"error": "in use: " + why, "in_use": why})
		return
	}
	var freed uint64
	entries := 1
	if fi.IsDir() {
		dev := uint64(0)
		if st := statT(fi); st != nil {
			dev = uint64(st.Dev)
		}
		if pfi, err := os.Lstat(filepath.Dir(p)); err == nil {
			if pst := statT(pfi); pst != nil && uint64(pst.Dev) != dev {
				writeErr(w, 403, p+" is a mount point")
				return
			}
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute)
		defer cancel()
		total, n, mount, err := fsTreeSize(ctx, p, dev)
		if err != nil {
			writeErr(w, 500, err.Error())
			return
		}
		if mount != "" {
			writeErr(w, 403, "contains a mount point: "+mount)
			return
		}
		freed, entries = total, n
		if err := os.RemoveAll(p); err != nil {
			writeErr(w, 500, err.Error())
			return
		}
	} else {
		if fi.Mode().IsRegular() {
			freed = uint64(fi.Size())
		}
		if err := os.Remove(p); err != nil {
			writeErr(w, 500, err.Error())
			return
		}
	}
	writeJSON(w, 200, map[string]any{"ok": true, "path": p, "freed_bytes": freed, "entries": entries})
}
