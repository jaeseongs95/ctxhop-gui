//go:build windows

package main

// This is an acquisition experiment, not a production DB route. No runtime
// caller, flag, environment switch, engine RPC, or canonical query is redirected.
import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"unsafe"
)

type snapshotEntry struct {
	File *os.File
	Info syscall.ByHandleFileInformation
	Hash string
}
type testSnapshot struct {
	Source, Private string
	Dirs            []snapshotEntry
	Files           map[string]snapshotEntry
	Copies          map[string]syscall.ByHandleFileInformation
	SID             string
	Closed          bool
}

func snapshotIdentity(a, b syscall.ByHandleFileInformation) bool {
	return a.VolumeSerialNumber == b.VolumeSerialNumber && a.FileIndexHigh == b.FileIndexHigh && a.FileIndexLow == b.FileIndexLow
}
func snapshotInfo(f *os.File, directory bool) (syscall.ByHandleFileInformation, error) {
	var info syscall.ByHandleFileInformation
	if e := syscall.GetFileInformationByHandle(syscall.Handle(f.Fd()), &info); e != nil {
		return info, e
	}
	if info.FileAttributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 || (info.FileAttributes&syscall.FILE_ATTRIBUTE_DIRECTORY != 0) != directory || (!directory && info.NumberOfLinks != 1) {
		return info, fmt.Errorf("snapshot identity/reparse/hardlink rejected: %s", f.Name())
	}
	// Resolve the opened handle, not just the path checked before opening.
	buf := make([]uint16, 32768)
	n, _, e := proc("GetFinalPathNameByHandleW").Call(f.Fd(), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0)
	if n == 0 || n >= uintptr(len(buf)) || !samePath(strings.TrimPrefix(syscall.UTF16ToString(buf[:n]), `\\?\`), f.Name()) {
		return info, fmt.Errorf("snapshot final path mismatch: %v", e)
	}
	return info, nil
}
func snapshotOpen(path string, directory bool) (snapshotEntry, error) {
	u, e := syscall.UTF16PtrFromString(path)
	if e != nil {
		return snapshotEntry{}, e
	}
	access, share, flags := uint32(syscall.GENERIC_READ), uint32(syscall.FILE_SHARE_READ), uint32(0x00200000)
	if directory {
		access, share, flags = 0x80, 3, 0x02200000 // directory metadata; no DELETE sharing
	}
	h, e := syscall.CreateFile(u, access, share, nil, syscall.OPEN_EXISTING, flags, 0)
	if e != nil {
		return snapshotEntry{}, e // no share relaxation or retry fallback
	}
	f := os.NewFile(uintptr(h), path)
	info, e := snapshotInfo(f, directory)
	if e != nil {
		return snapshotEntry{}, errors.Join(e, f.Close())
	}
	return snapshotEntry{File: f, Info: info}, nil
}
func (s *testSnapshot) lockDirs(path string) error {
	paths := []string{}
	for p := filepath.Clean(path); ; p = filepath.Dir(p) {
		paths = append(paths, p)
		if filepath.Dir(p) == p {
			break
		}
	}
	for i := len(paths) - 1; i >= 0; i-- {
		entry, e := snapshotOpen(paths[i], true)
		if e != nil {
			return e
		}
		s.Dirs = append(s.Dirs, entry)
	}
	return nil
}
func snapshotAbsent(path string) error {
	u, e := syscall.UTF16PtrFromString(path)
	if e != nil {
		return e
	}
	_, e = syscall.GetFileAttributes(u)
	if e == syscall.ERROR_FILE_NOT_FOUND {
		return nil
	}
	return fmt.Errorf("snapshot expected absence: %s (%v)", path, e)
}
func snapshotHash(f *os.File, max int64) (string, int64, error) {
	if _, e := f.Seek(0, io.SeekStart); e != nil {
		return "", 0, e
	}
	h := sha256.New()
	n, e := io.Copy(h, io.LimitReader(f, max+1))
	if e != nil || n > max {
		return "", n, fmt.Errorf("snapshot hash size/read error: %d %v", n, e)
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}
func snapshotSecurity() (string, *byte, error) {
	token, e := syscall.OpenCurrentProcessToken()
	if e != nil {
		return "", nil, e
	}
	user, e := token.GetTokenUser()
	closeErr := token.Close()
	if e != nil || closeErr != nil {
		return "", nil, errors.Join(e, closeErr)
	}
	sid, e := user.User.Sid.String()
	if e != nil {
		return "", nil, e
	}
	sddl, _ := syscall.UTF16PtrFromString("O:" + sid + "D:P(A;OICI;FA;;;" + sid + ")")
	var sd *byte
	r, _, e := syscall.NewLazyDLL("advapi32.dll").NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW").Call(uintptr(unsafe.Pointer(sddl)), 1, uintptr(unsafe.Pointer(&sd)), 0)
	if r == 0 {
		return "", nil, e
	}
	return sid, sd, nil
}
func snapshotACL(path, sid string) error {
	u, _ := syscall.UTF16PtrFromString(path)
	adv := syscall.NewLazyDLL("advapi32.dll")
	var sd *byte
	r, _, _ := adv.NewProc("GetNamedSecurityInfoW").Call(uintptr(unsafe.Pointer(u)), 1, 4, 0, 0, 0, 0, uintptr(unsafe.Pointer(&sd)))
	if r != 0 {
		return syscall.Errno(r)
	}
	defer proc("LocalFree").Call(uintptr(unsafe.Pointer(sd)))
	var text *uint16
	r, _, e := adv.NewProc("ConvertSecurityDescriptorToStringSecurityDescriptorW").Call(uintptr(unsafe.Pointer(sd)), 1, 4, uintptr(unsafe.Pointer(&text)), 0)
	if r == 0 {
		return e
	}
	defer proc("LocalFree").Call(uintptr(unsafe.Pointer(text)))
	// This native output is NUL-terminated. Copy via RtlMoveMemory, no uintptr cast.
	buf := make([]uint16, 1024)
	for i := range buf {
		proc("RtlMoveMemory").Call(uintptr(unsafe.Pointer(&buf[i])), uintptr(unsafe.Pointer(text))+uintptr(i*2), 2)
		if buf[i] == 0 {
			got := syscall.UTF16ToString(buf[:i])
			if got != "D:P(A;OICI;FA;;;"+sid+")" {
				return fmt.Errorf("snapshot DACL is not protected single-user: %s", got)
			}
			return nil
		}
	}
	return fmt.Errorf("snapshot DACL descriptor too long")
}
func acquireTestSnapshot(source, private string, max int64, hook func(string) error, copyBytes func(io.Writer, io.Reader) (int64, error)) (s *testSnapshot, retErr error) {
	s = &testSnapshot{Source: filepath.Clean(source), Private: filepath.Clean(private), Files: map[string]snapshotEntry{}, Copies: map[string]syscall.ByHandleFileInformation{}}
	if !filepath.IsAbs(source) || !filepath.IsAbs(private) || filepath.Base(source) != "state_5.sqlite" || samePath(filepath.Dir(source), private) || max < 100 || max > limit {
		return s, fmt.Errorf("snapshot arguments rejected")
	}
	created := false
	defer func() {
		if retErr != nil {
			retErr = errors.Join(retErr, s.Close(created))
		}
	}()
	if e := s.lockDirs(filepath.Dir(source)); e != nil {
		return s, e
	}
	if e := snapshotAbsent(source + "-journal"); e != nil {
		return s, e // any rollback journal is conservative failure
	}
	for _, name := range []string{"state_5.sqlite", "state_5.sqlite-wal"} {
		entry, e := snapshotOpen(filepath.Join(filepath.Dir(source), name), false)
		if name == "state_5.sqlite-wal" && e == syscall.ERROR_FILE_NOT_FOUND {
			continue
		}
		if e != nil {
			return s, e
		}
		s.Files[name] = entry
	}
	// Both handles are acquired before reading/copying either file.
	if hook != nil {
		if e := hook("locked"); e != nil {
			return s, e
		}
	}
	if e := s.lockDirs(filepath.Dir(private)); e != nil {
		return s, e
	}
	sid, sd, e := snapshotSecurity()
	if e != nil {
		return s, e
	}
	defer proc("LocalFree").Call(uintptr(unsafe.Pointer(sd)))
	s.SID = sid
	sa := syscall.SecurityAttributes{Length: uint32(unsafe.Sizeof(syscall.SecurityAttributes{})), SecurityDescriptor: uintptr(unsafe.Pointer(sd))}
	u, _ := syscall.UTF16PtrFromString(private)
	r, _, e := proc("CreateDirectoryW").Call(uintptr(unsafe.Pointer(u)), uintptr(unsafe.Pointer(&sa)))
	if r == 0 {
		return s, e
	}
	created = true
	if e := s.lockDirs(private); e != nil {
		return s, e
	}
	if e := snapshotACL(private, sid); e != nil {
		return s, e // before any private bytes are written
	}
	if hook != nil {
		if e := hook("private"); e != nil {
			return s, e
		}
	}
	var total int64
	for _, name := range []string{"state_5.sqlite", "state_5.sqlite-wal"} {
		entry, exists := s.Files[name]
		if !exists {
			continue
		}
		hash, size, e := snapshotHash(entry.File, max)
		if e != nil || size != int64(entry.Info.FileSizeHigh)<<32|int64(entry.Info.FileSizeLow) {
			return s, fmt.Errorf("snapshot source size mismatch: %w", e)
		}
		entry.Hash = hash
		s.Files[name] = entry
		total += size
		if total > max {
			return s, fmt.Errorf("snapshot combined size limit")
		}
		if _, e = entry.File.Seek(0, io.SeekStart); e != nil {
			return s, e
		}
		path := filepath.Join(private, name)
		u, _ := syscall.UTF16PtrFromString(path)
		h, e := syscall.CreateFile(u, syscall.GENERIC_READ|syscall.GENERIC_WRITE, syscall.FILE_SHARE_READ, &sa, syscall.CREATE_NEW, 0x00200000, 0)
		if e != nil {
			return s, e
		}
		out := os.NewFile(uintptr(h), path)
		info, e := snapshotInfo(out, false)
		if e == nil && snapshotIdentity(info, entry.Info) {
			e = fmt.Errorf("snapshot shares source identity")
		}
		if e != nil {
			return s, errors.Join(e, out.Close())
		}
		s.Copies[name] = info
		if e := snapshotACL(path, sid); e != nil {
			return s, errors.Join(e, out.Close())
		}
		var n int64
		if copyBytes == nil {
			n, e = io.Copy(out, io.LimitReader(entry.File, max+1))
		} else {
			n, e = copyBytes(out, io.LimitReader(entry.File, max+1))
		}
		if e == nil && n != size {
			e = fmt.Errorf("snapshot partial copy: %d != %d", n, size)
		}
		if e == nil {
			e = out.Sync()
		}
		if e == nil {
			var copied string
			copied, _, e = snapshotHash(out, max)
			if e == nil && copied != hash {
				e = fmt.Errorf("snapshot copy hash mismatch")
			}
		}
		e = errors.Join(e, out.Close())
		if e != nil {
			return s, e
		}
	}
	if hook != nil {
		if e := hook("copied"); e != nil {
			return s, e
		}
	}
	return s, s.Verify(max)
}
func (s *testSnapshot) Verify(max int64) error {
	if s.Closed {
		return fmt.Errorf("snapshot handles already drained")
	}
	if e := snapshotAbsent(s.Source + "-journal"); e != nil {
		return e
	}
	if _, exists := s.Files["state_5.sqlite-wal"]; !exists {
		if e := snapshotAbsent(s.Source + "-wal"); e != nil {
			return e
		}
	}
	for _, entry := range s.Dirs {
		info, e := snapshotInfo(entry.File, true)
		if e != nil || !snapshotIdentity(info, entry.Info) {
			return fmt.Errorf("snapshot ancestor changed: %v", e)
		}
	}
	for _, entry := range s.Files {
		info, e := snapshotInfo(entry.File, false)
		if e != nil || !snapshotIdentity(info, entry.Info) || info.FileSizeHigh != entry.Info.FileSizeHigh || info.FileSizeLow != entry.Info.FileSizeLow {
			return fmt.Errorf("snapshot source identity/size changed: %v", e)
		}
		hash, _, e := snapshotHash(entry.File, max)
		if e != nil || hash != entry.Hash {
			return fmt.Errorf("snapshot source hash changed: %v", e)
		}
	}
	return nil
}
func (s *testSnapshot) Close(clean bool) error {
	if s.Closed {
		return nil
	}
	s.Closed = true
	var result error
	for _, entry := range s.Files {
		result = errors.Join(result, entry.File.Close())
	}
	for i := len(s.Dirs) - 1; i >= 0; i-- {
		result = errors.Join(result, s.Dirs[i].File.Close())
	}
	if result != nil || !clean {
		return result
	}
	if e := noReparse(s.Private); e != nil {
		return e
	}
	privateEntry, e := snapshotOpen(s.Private, true)
	if e != nil {
		return e
	}
	privateSame := false
	for _, dir := range s.Dirs {
		if samePath(dir.File.Name(), s.Private) && snapshotIdentity(dir.Info, privateEntry.Info) {
			privateSame = true
		}
	}
	if e := privateEntry.File.Close(); e != nil {
		return e
	}
	if !privateSame {
		return fmt.Errorf("snapshot cleanup directory identity changed")
	}
	entries, e := os.ReadDir(s.Private)
	if e != nil {
		return e
	}
	for _, item := range entries {
		name := item.Name()
		if name != "state_5.sqlite" && name != "state_5.sqlite-wal" && name != "state_5.sqlite-shm" {
			return fmt.Errorf("snapshot cleanup refused unknown entry: %s", name)
		}
		entry, e := snapshotOpen(filepath.Join(s.Private, name), false)
		if e != nil {
			return e
		}
		original, exists := s.Copies[name]
		if !exists || !snapshotIdentity(original, entry.Info) {
			return errors.Join(fmt.Errorf("snapshot cleanup identity changed"), entry.File.Close())
		}
		if e = entry.File.Close(); e != nil {
			return e
		}
	}
	for _, item := range entries {
		if e := os.Remove(filepath.Join(s.Private, item.Name())); e != nil {
			return e
		}
	}
	return os.Remove(s.Private)
}

func snapshotAcquire(t *testing.T, source string) *testSnapshot {
	t.Helper()
	s, e := acquireTestSnapshot(source, filepath.Join(t.TempDir(), "private"), limit, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		if !s.Closed {
			if e := s.Close(true); e != nil {
				t.Error(e)
			}
		}
	})
	return s
}
