//go:build windows

package main

// Raw source acquisition and owned private SQLite namespace. Config/home/stateDb
// retain their canonical source meaning; only inspection receives a private path.
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
	"unsafe"
)

type snapshotEntry struct {
	File *os.File
	Info syscall.ByHandleFileInformation
	Hash string
}
type dbAcquisition struct {
	Source, Private string
	Dirs            []snapshotEntry
	Files           map[string]snapshotEntry
	Copies          map[string]syscall.ByHandleFileInformation
	SID             string
	Pinned          bool
	PrivateCreated  bool
	Finalized       bool
	Closed          bool
	PrivateRemoved  bool
	CloseErr        error
	ID              string
	SourceDir       syscall.ByHandleFileInformation
	PrivateDir      syscall.ByHandleFileInformation
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
func (s *dbAcquisition) lockDirs(path string) error {
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
	return snapshotOwnedACL(path, sid, false)
}
func snapshotOwnedACL(path, sid string, inheritedSidecar bool) error {
	u, _ := syscall.UTF16PtrFromString(path)
	adv := syscall.NewLazyDLL("advapi32.dll")
	var sd *byte
	r, _, _ := adv.NewProc("GetNamedSecurityInfoW").Call(uintptr(unsafe.Pointer(u)), 1, 5, 0, 0, 0, 0, uintptr(unsafe.Pointer(&sd)))
	if r != 0 {
		return syscall.Errno(r)
	}
	defer proc("LocalFree").Call(uintptr(unsafe.Pointer(sd)))
	var text *uint16
	r, _, e := adv.NewProc("ConvertSecurityDescriptorToStringSecurityDescriptorW").Call(uintptr(unsafe.Pointer(sd)), 1, 5, uintptr(unsafe.Pointer(&text)), 0)
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
			protected := "O:" + sid + "D:P(A;OICI;FA;;;" + sid + ")"
			inherited := "O:" + sid + "D:(A;ID;FA;;;" + sid + ")"
			if got != protected && !(inheritedSidecar && got == inherited) {
				return fmt.Errorf("snapshot DACL is not protected single-user: %s", got)
			}
			return nil
		}
	}
	return fmt.Errorf("snapshot DACL descriptor too long")
}

// Internal canonical filenames do not grant provider descriptor authority.
func snapshotCanonicalBase(name string) bool {
	switch name {
	case "state_5.sqlite", "logs_2.sqlite", "goals_1.sqlite", "memories_1.sqlite", "memories_v2_1.sqlite", "queue_1.sqlite", "thread_history_1.sqlite", "agent_message_board_1.sqlite":
		return true
	}
	return false
}

// Pin performs metadata operations only, including for an existing SHM. A set
// owner must pin every source before calling any member's finalizeCopy.
func pinSnapshotSource(source string, max int64) (s *dbAcquisition, retErr error) {
	s = &dbAcquisition{Source: filepath.Clean(source), ID: nonce(), Files: map[string]snapshotEntry{}, Copies: map[string]syscall.ByHandleFileInformation{}}
	defer func() {
		if retErr != nil {
			retErr = errors.Join(retErr, s.releaseLeases())
		}
	}()
	if !filepath.IsAbs(source) || !snapshotCanonicalBase(filepath.Base(source)) || max < 100 || max > limit {
		return s, fmt.Errorf("snapshot source arguments rejected")
	}
	if e := s.lockDirs(filepath.Dir(source)); e != nil {
		return s, e
	}
	s.SourceDir = s.Dirs[len(s.Dirs)-1].Info
	if e := snapshotAbsent(source + "-journal"); e != nil {
		return s, e // any rollback journal is conservative failure
	}
	base := filepath.Base(source)
	for _, name := range []string{base, base + "-wal", base + "-shm"} {
		entry, e := snapshotOpen(filepath.Join(filepath.Dir(source), name), false)
		if name != base && e == syscall.ERROR_FILE_NOT_FOUND {
			continue
		}
		if e != nil {
			return s, e
		}
		s.Files[name] = entry
	}
	if _, e := s.sourceBytes(max); e != nil {
		return s, e
	}
	s.Pinned = true
	return s, nil
}

// Unsigned metadata and subtraction avoid overflow before any byte is read.
// The aggregate owner sums these main/WAL budgets once across all sources.
func (s *dbAcquisition) sourceBytes(max int64) (int64, error) {
	if max < 100 || max > limit {
		return 0, fmt.Errorf("snapshot size bound rejected")
	}
	var total uint64
	base := filepath.Base(s.Source)
	for name, entry := range s.Files {
		size := uint64(entry.Info.FileSizeHigh)<<32 | uint64(entry.Info.FileSizeLow)
		if name == base+"-shm" {
			if size > uint64(lineLimit) {
				return 0, fmt.Errorf("snapshot SHM size limit")
			}
			continue
		}
		if name != base && name != base+"-wal" || size > uint64(max)-total {
			return 0, fmt.Errorf("snapshot combined size limit")
		}
		total += size
	}
	return int64(total), nil
}

func (s *dbAcquisition) createPrivate(private string) error {
	if !s.Pinned || s.Closed || s.PrivateCreated || s.Finalized || !filepath.IsAbs(private) || within(filepath.Dir(s.Source), private) || within(private, filepath.Dir(s.Source)) {
		return fmt.Errorf("snapshot private phase/arguments rejected")
	}
	s.Private = filepath.Clean(private)
	if e := s.lockDirs(filepath.Dir(private)); e != nil {
		return e
	}
	sid, sd, e := snapshotSecurity()
	if e != nil {
		return e
	}
	defer proc("LocalFree").Call(uintptr(unsafe.Pointer(sd)))
	s.SID = sid
	sa := syscall.SecurityAttributes{Length: uint32(unsafe.Sizeof(syscall.SecurityAttributes{})), SecurityDescriptor: uintptr(unsafe.Pointer(sd))}
	u, _ := syscall.UTF16PtrFromString(private)
	r, _, e := proc("CreateDirectoryW").Call(uintptr(unsafe.Pointer(u)), uintptr(unsafe.Pointer(&sa)))
	if r == 0 {
		return e
	}
	s.PrivateCreated = true
	if e := s.lockDirs(private); e != nil {
		return e
	}
	s.PrivateDir = s.Dirs[len(s.Dirs)-1].Info
	if e := snapshotACL(private, sid); e != nil {
		return e // before any private bytes are written
	}
	return nil
}

func (s *dbAcquisition) finalizeCopy(max int64, copyBytes func(io.Writer, io.Reader) (int64, error)) error {
	if !s.Pinned || !s.PrivateCreated || s.Finalized || s.Closed {
		return fmt.Errorf("snapshot finalize phase rejected")
	}
	if e := s.verifySourceMetadata(max); e != nil {
		return e
	}
	if e := snapshotACL(s.Private, s.SID); e != nil {
		return e
	}
	sid, sd, e := snapshotSecurity()
	if e != nil {
		return e
	}
	defer proc("LocalFree").Call(uintptr(unsafe.Pointer(sd)))
	if sid != s.SID {
		return fmt.Errorf("snapshot private owner changed")
	}
	sa := syscall.SecurityAttributes{Length: uint32(unsafe.Sizeof(syscall.SecurityAttributes{})), SecurityDescriptor: uintptr(unsafe.Pointer(sd))}
	base := filepath.Base(s.Source)
	if entry, exists := s.Files[base+"-shm"]; exists {
		hash, size, e := snapshotHash(entry.File, lineLimit)
		if e != nil || size != snapshotSize(entry.Info) {
			return fmt.Errorf("snapshot SHM size/read mismatch: %v", e)
		}
		entry.Hash = hash
		s.Files[base+"-shm"] = entry
	}
	for _, name := range []string{base, base + "-wal"} {
		entry, exists := s.Files[name]
		if !exists {
			continue
		}
		hash, size, e := snapshotHash(entry.File, max)
		if e != nil || size != snapshotSize(entry.Info) {
			return fmt.Errorf("snapshot source size mismatch: %v", e)
		}
		entry.Hash = hash
		s.Files[name] = entry
		if _, e = entry.File.Seek(0, io.SeekStart); e != nil {
			return e
		}
		path := filepath.Join(s.Private, name)
		u, _ := syscall.UTF16PtrFromString(path)
		h, e := syscall.CreateFile(u, syscall.GENERIC_READ|syscall.GENERIC_WRITE, syscall.FILE_SHARE_READ, &sa, syscall.CREATE_NEW, 0x00200000, 0)
		if e != nil {
			return e
		}
		out := os.NewFile(uintptr(h), path)
		info, e := snapshotInfo(out, false)
		if e == nil && snapshotIdentity(info, entry.Info) {
			e = fmt.Errorf("snapshot shares source identity")
		}
		if e != nil {
			return errors.Join(e, out.Close())
		}
		s.Copies[name] = info
		if e := snapshotACL(path, sid); e != nil {
			return errors.Join(e, out.Close())
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
		if e == nil {
			info, e = snapshotInfo(out, false)
			if e == nil {
				s.Copies[name] = info
			}
		}
		e = errors.Join(e, out.Close())
		if e != nil {
			return e
		}
	}
	if e := s.verifySourceBytes(max); e != nil {
		return e
	}
	s.Finalized = true
	return nil
}

// The v1 state-only wrapper retains its wire and hook order. Set acquisition
// uses the individual phases, not eight calls to this copying wrapper.
func acquireSnapshot(source, private string, max int64, hook func(string) error, copyBytes func(io.Writer, io.Reader) (int64, error)) (s *dbAcquisition, retErr error) {
	if !filepath.IsAbs(private) || filepath.Base(source) != "state_5.sqlite" || within(filepath.Dir(source), private) || within(private, filepath.Dir(source)) {
		return &dbAcquisition{}, fmt.Errorf("snapshot arguments rejected")
	}
	s, retErr = pinSnapshotSource(source, max)
	if retErr != nil {
		return s, retErr
	}
	defer func() {
		if retErr != nil {
			retErr = errors.Join(retErr, s.Close(true))
		}
	}()
	if hook != nil {
		if e := hook("locked"); e != nil {
			return s, e
		}
	}
	if e := s.createPrivate(private); e != nil {
		return s, e
	}
	if hook != nil {
		if e := hook("private"); e != nil {
			return s, e
		}
	}
	if e := s.finalizeCopy(max, copyBytes); e != nil {
		return s, e
	}
	if hook != nil {
		if e := hook("copied"); e != nil {
			return s, e
		}
	}
	return s, s.Verify(max)
}
func (s *dbAcquisition) Verify(max int64) error {
	if !s.Finalized {
		return fmt.Errorf("snapshot copy not finalized")
	}
	return s.verifySourceBytes(max)
}

func (s *dbAcquisition) verifySourceMetadata(max int64) error {
	if !s.Pinned || s.Closed {
		return fmt.Errorf("snapshot source not pinned or handles already drained")
	}
	if e := snapshotAbsent(s.Source + "-journal"); e != nil {
		return e
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		if _, exists := s.Files[filepath.Base(s.Source)+suffix]; !exists {
			if e := snapshotAbsent(s.Source + suffix); e != nil {
				return e
			}
		}
	}
	for _, entry := range s.Dirs {
		if entry.File == nil {
			continue
		}
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
	}
	_, e := s.sourceBytes(max)
	return e
}

func (s *dbAcquisition) verifySourceBytes(max int64) error {
	if e := s.verifySourceMetadata(max); e != nil {
		return e
	}
	for name, entry := range s.Files {
		bound := max
		if name == filepath.Base(s.Source)+"-shm" {
			bound = lineLimit
		}
		hash, _, e := snapshotHash(entry.File, bound)
		if e != nil || hash != entry.Hash {
			return fmt.Errorf("snapshot source hash changed: %v", e)
		}
	}
	return nil
}

func snapshotFileID(info syscall.ByHandleFileInformation) string {
	return fmt.Sprintf("%08x%08x%08x", info.VolumeSerialNumber, info.FileIndexHigh, info.FileIndexLow)
}
func snapshotSize(info syscall.ByHandleFileInformation) int64 {
	return int64(info.FileSizeHigh)<<32 | int64(info.FileSizeLow)
}
func (s *dbAcquisition) Observation() (object, error) {
	if filepath.Base(s.Source) != "state_5.sqlite" {
		return nil, fmt.Errorf("v1 observation requires state acquisition")
	}
	if e := s.Verify(limit); e != nil {
		return nil, e
	}
	describe := func(name string, private bool) any {
		entry, exists := s.Files[name]
		if !exists {
			return nil
		}
		info := entry.Info
		if private {
			info = s.Copies[name]
		}
		return object{"identity": snapshotFileID(info), "size": snapshotSize(info), "sha256": entry.Hash}
	}
	main := s.Files["state_5.sqlite"]
	var wal any
	if entry, exists := s.Files["state_5.sqlite-wal"]; exists {
		wal = entry.Hash
	}
	return object{"stateDb": s.Source, "mainSha256": main.Hash, "walSha256": wal, "acquisition": object{
		"schemaVersion": 1, "acquisitionId": s.ID,
		"source":                object{"directoryIdentity": snapshotFileID(s.SourceDir), "main": describe("state_5.sqlite", false), "wal": describe("state_5.sqlite-wal", false), "shm": describe("state_5.sqlite-shm", false)},
		"private":               object{"directory": s.Private, "directoryIdentity": snapshotFileID(s.PrivateDir), "main": describe("state_5.sqlite", true), "wal": describe("state_5.sqlite-wal", true)},
		"rollbackJournalAbsent": true,
	}}, nil
}

// Run only after every Go/provider private reader has closed. Register permitted
// private sidecars without changing the original presence captured by Files.
func (s *dbAcquisition) VerifyPrivate() error {
	if !s.Finalized || !s.PrivateCreated || s.Closed || s.PrivateRemoved {
		return fmt.Errorf("snapshot private copy not finalized or namespace drained")
	}
	base := filepath.Base(s.Source)
	if e := snapshotAbsent(filepath.Join(s.Private, base+"-journal")); e != nil {
		return e
	}
	if e := snapshotACL(s.Private, s.SID); e != nil {
		return e
	}
	for _, name := range []string{base, base + "-wal", base + "-shm"} {
		entry, e := snapshotOpen(filepath.Join(s.Private, name), false)
		source, copied := s.Files[name]
		copied = copied && name != base+"-shm"
		if e == syscall.ERROR_FILE_NOT_FOUND && !copied {
			continue
		}
		if e != nil {
			return e
		}
		e = func() error {
			if e := snapshotOwnedACL(entry.File.Name(), s.SID, !copied); e != nil {
				return e
			}
			if old, exists := s.Copies[name]; exists && !snapshotIdentity(old, entry.Info) {
				return fmt.Errorf("snapshot private identity changed")
			}
			size := snapshotSize(entry.Info)
			if copied {
				hash, n, e := snapshotHash(entry.File, limit)
				if e != nil || n != snapshotSize(source.Info) || hash != source.Hash {
					return fmt.Errorf("snapshot private copied bytes changed: %v", e)
				}
			} else if (name == base+"-wal" && size != 0) || (name == base+"-shm" && size > lineLimit) {
				return fmt.Errorf("snapshot private sidecar size rejected")
			}
			s.Copies[name] = entry.Info
			return nil
		}()
		if e = errors.Join(e, entry.File.Close()); e != nil {
			return e
		}
	}
	return s.Verify(limit)
}

// Fresh raw-only source acquisition after private cleanup/source release. This
// observes a handoff gap; it does not turn the observation into a writer lease.
func (s *dbAcquisition) VerifyReleasedSource() (retErr error) {
	if !s.Finalized || !s.Closed || s.CloseErr != nil || !s.PrivateRemoved {
		return fmt.Errorf("snapshot source handoff before successful cleanup/drain")
	}
	fresh, e := pinSnapshotSource(s.Source, limit)
	if e != nil {
		return e
	}
	defer func() { retErr = errors.Join(retErr, fresh.releaseLeases()) }()
	if !snapshotIdentity(fresh.SourceDir, s.SourceDir) {
		return fmt.Errorf("snapshot source directory changed after release")
	}
	base := filepath.Base(s.Source)
	for _, name := range []string{base, base + "-wal", base + "-shm"} {
		expected, exists := s.Files[name]
		entry, present := fresh.Files[name]
		if exists != present {
			return fmt.Errorf("snapshot source presence changed after release")
		}
		if !present {
			continue
		}
		if !snapshotIdentity(entry.Info, expected.Info) || snapshotSize(entry.Info) != snapshotSize(expected.Info) {
			return fmt.Errorf("snapshot source identity/size changed after release")
		}
		entry.Hash = expected.Hash
		fresh.Files[name] = entry
	}
	return fresh.verifySourceBytes(limit)
}
func (s *dbAcquisition) Close(clean bool) error {
	if s.Closed {
		return s.CloseErr
	}
	// Private readers must already be drained. Source leases remain held through
	// identity-checked cleanup, including errors; every lease is then drained.
	if clean && s.PrivateCreated {
		s.CloseErr = errors.Join(s.CloseErr, s.CleanupPrivate())
	}
	return s.releaseLeases()
}

// A set owner calls this only after all members' private cleanup has finished.
// Pin failures also use it; it never starts cleanup or reads source bytes.
func (s *dbAcquisition) releaseLeases() error {
	if s.Closed {
		return s.CloseErr
	}
	for _, entry := range s.Files {
		s.CloseErr = errors.Join(s.CloseErr, entry.File.Close())
	}
	for i := len(s.Dirs) - 1; i >= 0; i-- {
		if s.Dirs[i].File != nil {
			s.CloseErr = errors.Join(s.CloseErr, s.Dirs[i].File.Close())
			s.Dirs[i].File = nil
		}
	}
	s.Closed = true
	return s.CloseErr
}
func (s *dbAcquisition) CleanupPrivate() error {
	if !s.PrivateCreated || s.Closed {
		return fmt.Errorf("snapshot cleanup before private creation or after source release")
	}
	if s.PrivateRemoved {
		return nil
	}
	if e := noReparse(s.Private); e != nil {
		return e
	}
	privateEntry, e := snapshotOpen(s.Private, true)
	if e != nil {
		return e
	}
	privateSame := false
	privateIndex := -1
	for i, dir := range s.Dirs {
		if dir.File != nil && samePath(dir.File.Name(), s.Private) && snapshotIdentity(dir.Info, privateEntry.Info) {
			privateSame = true
			privateIndex = i
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
	base := filepath.Base(s.Source)
	for _, item := range entries {
		name := item.Name()
		if name != base && name != base+"-wal" && name != base+"-shm" {
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
	// Only the private directory's no-DELETE handle must be released to remove
	// it. Source directories and private ancestors remain anchored until Close.
	if e := s.Dirs[privateIndex].File.Close(); e != nil {
		return e
	}
	s.Dirs[privateIndex].File = nil
	if e := os.Remove(s.Private); e != nil {
		return e
	}
	s.PrivateRemoved = true
	return nil
}
