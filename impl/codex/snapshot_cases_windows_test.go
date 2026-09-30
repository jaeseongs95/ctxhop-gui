//go:build windows

package main

import (
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"unsafe"
)

func snapshotFixture(t *testing.T, walOnly bool) string {
	t.Helper()
	original := t.TempDir()
	closeDB := sqliteFixture(t, original, true, fixtureSQL+` INSERT INTO threads VALUES('`+rootID+`');`)
	if !walOnly {
		closeDB() // genuine closed, checkpointed WAL-mode main with no WAL
	}
	home := t.TempDir()
	for _, suffix := range []string{"", "-wal"} {
		b, e := os.ReadFile(filepath.Join(original, "state_5.sqlite") + suffix)
		if os.IsNotExist(e) && suffix == "-wal" {
			continue
		}
		if e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(filepath.Join(home, "state_5.sqlite")+suffix, b, 0600); e != nil {
			t.Fatal(e)
		}
	}
	if walOnly {
		closeDB()
	}
	return filepath.Join(home, "state_5.sqlite")
}

// Opens only the explicit private snapshot; no production/checkDB redirect.
// SELECT is the only SQL. SQLite may create private WAL/SHM, never source sidecars.
func snapshotCount(s *testSnapshot) (count int, retErr error) {
	system, e := systemDirectory()
	if e != nil {
		return 0, e
	}
	dll, e := syscall.LoadDLL(filepath.Join(system, "winsqlite3.dll"))
	if e != nil {
		return 0, e
	}
	defer dll.Release()
	var db uintptr
	uri := url.URL{Scheme: "file", Path: "/" + filepath.ToSlash(filepath.Join(s.Private, "state_5.sqlite")), RawQuery: "mode=ro"}
	b := append([]byte(uri.String()), 0)
	r, _, _ := dll.MustFindProc("sqlite3_open_v2").Call(uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(&db)), 0x41, 0)
	if db != 0 {
		defer func() {
			rc, _, _ := dll.MustFindProc("sqlite3_close").Call(db)
			if rc != 0 {
				retErr = errors.Join(retErr, fmt.Errorf("private SQLite drain: %d", rc))
			}
		}()
	}
	if r != 0 {
		return 0, fmt.Errorf("private SQLite open: %d", r)
	}
	b = append([]byte("SELECT count(*) FROM threads"), 0)
	var stmt uintptr
	r, _, _ = dll.MustFindProc("sqlite3_prepare_v2").Call(db, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)-1), uintptr(unsafe.Pointer(&stmt)), 0)
	if r != 0 {
		return 0, fmt.Errorf("private SQLite prepare: %d", r)
	}
	defer func() {
		rc, _, _ := dll.MustFindProc("sqlite3_finalize").Call(stmt)
		if rc != 0 {
			retErr = errors.Join(retErr, fmt.Errorf("private SQLite stmt drain: %d", rc))
		}
	}()
	r, _, _ = dll.MustFindProc("sqlite3_step").Call(stmt)
	if r != 100 {
		return 0, fmt.Errorf("private SQLite step: %d", r)
	}
	n, _, _ := dll.MustFindProc("sqlite3_column_int").Call(stmt, 0)
	return int(n), nil
}
func snapshotRegisterSidecars(s *testSnapshot) error {
	// Called only after the owned private SQLite connection has been drained.
	for _, name := range []string{"state_5.sqlite-wal", "state_5.sqlite-shm"} {
		entry, e := snapshotOpen(filepath.Join(s.Private, name), false)
		if e == syscall.ERROR_FILE_NOT_FOUND {
			continue
		}
		if e != nil {
			return e
		}
		if old, exists := s.Copies[name]; exists && !snapshotIdentity(old, entry.Info) {
			return errors.Join(fmt.Errorf("private sidecar replaced"), entry.File.Close())
		}
		s.Copies[name] = entry.Info
		if e := entry.File.Close(); e != nil {
			return e
		}
	}
	return nil
}
func TestSnapshotCheckpointEmptyWALAndWALOnly(t *testing.T) {
	for _, mode := range []string{"checkpoint-no-WAL", "empty-WAL", "WAL-only-commit", "stale-SHM"} {
		t.Run(mode, func(t *testing.T) {
			source := snapshotFixture(t, mode == "WAL-only-commit" || mode == "stale-SHM")
			if mode == "empty-WAL" {
				if e := os.WriteFile(source+"-wal", nil, 0600); e != nil {
					t.Fatal(e)
				}
			}
			if mode == "stale-SHM" {
				if e := os.WriteFile(source+"-shm", []byte("stale private-fixture SHM"), 0600); e != nil {
					t.Fatal(e)
				}
			}
			before, e := dbHashes(source)
			if e != nil {
				t.Fatal(e)
			}
			s := snapshotAcquire(t, source)
			if e := snapshotACL(s.Private, s.SID); e != nil {
				t.Fatal(e)
			}
			if _, e := os.Stat(filepath.Join(s.Private, "state_5.sqlite-shm")); !os.IsNotExist(e) {
				t.Fatal("source SHM was copied")
			}
			count, e := snapshotCount(s)
			if e != nil || count != 1 {
				t.Fatal(e, count)
			}
			if e := snapshotRegisterSidecars(s); e != nil {
				t.Fatal(e)
			}
			if e := s.Verify(limit); e != nil {
				t.Fatal(e)
			}
			after, e := dbHashes(source)
			if e != nil || string(encoded(before)) != string(encoded(after)) {
				t.Fatal("source main/WAL changed", e)
			}
			if mode == "stale-SHM" {
				b, e := os.ReadFile(source + "-shm")
				if e != nil || string(b) != "stale private-fixture SHM" {
					t.Fatal("source SHM changed", e)
				}
			}
			t.Logf("source main/WAL unchanged; private SELECT count=%d; source WAL present=%t; distinct file IDs; protected single-user DACL; source SHM not copied", count, before[source+"-wal"] != "absent")
			if e := s.Close(true); e != nil {
				t.Fatal(e)
			}
			if _, e := os.Stat(s.Private); !os.IsNotExist(e) {
				t.Fatal("private cleanup", e)
			}
		})
	}
}
func TestSnapshotRejectsJournalAndAbsentWALChange(t *testing.T) {
	t.Run("hot-journal", func(t *testing.T) {
		original := t.TempDir()
		sql := fixtureSQL + ` CREATE TABLE payload(id INTEGER PRIMARY KEY,v BLOB); PRAGMA cache_size=1; BEGIN IMMEDIATE;` + strings.Repeat(`INSERT INTO payload(v) VALUES(zeroblob(8000));`, 20)
		closeDB := sqliteFixture(t, original, false, sql)
		defer closeDB()
		home := t.TempDir()
		for _, suffix := range []string{"", "-journal"} {
			b, e := os.ReadFile(filepath.Join(original, "state_5.sqlite") + suffix)
			if e != nil {
				t.Fatal(e)
			}
			if suffix == "-journal" && (len(b) < 8 || string(b[:8]) != "\xd9\xd5\x05\xf9\x20\xa1\x63\xd7") {
				t.Fatal("hot-journal fixture did not contain journal magic")
			}
			if e := os.WriteFile(filepath.Join(home, "state_5.sqlite")+suffix, b, 0600); e != nil {
				t.Fatal(e)
			}
		}
		_, e := acquireTestSnapshot(filepath.Join(home, "state_5.sqlite"), filepath.Join(t.TempDir(), "private"), limit, nil, nil)
		if e == nil {
			t.Fatal("hot journal accepted")
		}
	})
	for _, suffix := range []string{"-wal", "-journal"} {
		t.Run("absent-becomes-present"+suffix, func(t *testing.T) {
			source := snapshotFixture(t, false)
			private := filepath.Join(t.TempDir(), "private")
			s, e := acquireTestSnapshot(source, private, limit, func(phase string) error {
				if phase == "copied" {
					return os.WriteFile(source+suffix, nil, 0600)
				}
				return nil
			}, nil)
			if e == nil || !s.Closed {
				t.Fatal("changed absence accepted/handles retained", e)
			}
			if _, e := os.Stat(private); !os.IsNotExist(e) {
				t.Fatal("failed acquisition did not clean private files", e)
			}
		})
	}
}
func TestSnapshotPartialSizeAndFreshCreation(t *testing.T) {
	for _, mode := range []string{"partial-error", "partial-success", "size", "existing-private", "existing-copy"} {
		t.Run(mode, func(t *testing.T) {
			source := snapshotFixture(t, false)
			before, _ := dbHashes(source)
			private := filepath.Join(t.TempDir(), "private")
			max := limit
			var copyBytes func(io.Writer, io.Reader) (int64, error)
			var hook func(string) error
			if strings.HasPrefix(mode, "partial") {
				copyBytes = func(w io.Writer, r io.Reader) (int64, error) {
					n, e := io.CopyN(w, r, 100)
					if mode == "partial-error" {
						e = io.ErrUnexpectedEOF
					}
					return n, e
				}
			}
			if mode == "size" {
				max = 100
			}
			if mode == "existing-private" {
				if e := os.Mkdir(private, 0700); e != nil {
					t.Fatal(e)
				}
				os.WriteFile(filepath.Join(private, "sentinel"), []byte("preserve"), 0600)
			}
			if mode == "existing-copy" {
				hook = func(phase string) error {
					if phase == "private" {
						return os.WriteFile(filepath.Join(private, "state_5.sqlite"), []byte("preserve"), 0600)
					}
					return nil
				}
			}
			s, e := acquireTestSnapshot(source, private, max, hook, copyBytes)
			if e == nil || !s.Closed {
				t.Fatal("invalid copy accepted/handles retained", e)
			}
			after, _ := dbHashes(source)
			if string(encoded(before)) != string(encoded(after)) {
				t.Fatal("source changed")
			}
			if mode == "existing-private" || mode == "existing-copy" {
				name := "sentinel"
				if mode == "existing-copy" {
					name = "state_5.sqlite"
				}
				b, e := os.ReadFile(filepath.Join(private, name))
				if e != nil || string(b) != "preserve" {
					t.Fatal("existing bytes overwritten/deleted", e)
				}
			} else if _, e := os.Stat(private); !os.IsNotExist(e) {
				t.Fatal("partial copy cleanup", e)
			}
		})
	}
}
func TestSnapshotSharingIdentityAndDrain(t *testing.T) {
	source := snapshotFixture(t, false)
	u, _ := syscall.UTF16PtrFromString(source)
	reader, e := syscall.CreateFile(u, syscall.GENERIC_READ, 7, nil, syscall.OPEN_EXISTING, 0, 0)
	if e != nil {
		t.Fatal(e)
	}
	s := snapshotAcquire(t, source)
	if e := syscall.CloseHandle(reader); e != nil {
		t.Fatal(e)
	}
	for _, access := range []uint32{syscall.GENERIC_WRITE, 0x10000} { // writer and DELETE
		h, e := syscall.CreateFile(u, access, 7, nil, syscall.OPEN_EXISTING, 0, 0)
		if e == nil {
			syscall.CloseHandle(h)
			t.Fatal("writer/delete entered while source held")
		}
		if e != syscall.Errno(32) {
			t.Fatal("unexpected share rejection", e)
		}
	}
	if e := os.Rename(filepath.Dir(source), filepath.Dir(source)+"-swapped"); e == nil {
		t.Fatal("ancestor rename entered while held")
	}
	handle := syscall.Handle(s.Files["state_5.sqlite"].File.Fd())
	if e := s.Close(true); e != nil {
		t.Fatal(e)
	}
	var info syscall.ByHandleFileInformation
	if e := syscall.GetFileInformationByHandle(handle, &info); e != syscall.ERROR_INVALID_HANDLE {
		t.Fatal("source handle not drained", e)
	}
	writer, e := syscall.CreateFile(u, syscall.GENERIC_WRITE, 7, nil, syscall.OPEN_EXISTING, 0, 0)
	if e != nil {
		t.Fatal("writer could not enter after drain", e)
	}
	if e := syscall.CloseHandle(writer); e != nil {
		t.Fatal(e)
	}
	t.Log("raw reader coexisted; writer/delete/ancestor rename rejected; handle drained; writer entered after release (activation handoff gap)")
}
func TestSnapshotHardlinkReparseAndCleanupFailure(t *testing.T) {
	for _, mode := range []string{"source-hardlink", "ancestor-junction", "private-hardlink", "unknown-entry", "cleanup-share"} {
		t.Run(mode, func(t *testing.T) {
			source := snapshotFixture(t, false)
			if mode == "source-hardlink" {
				if e := os.Link(source, filepath.Join(t.TempDir(), "alias")); e != nil {
					t.Fatal(e)
				}
				if _, e := acquireTestSnapshot(source, filepath.Join(t.TempDir(), "private"), limit, nil, nil); e == nil {
					t.Fatal("source hardlink accepted")
				}
				return
			}
			if mode == "ancestor-junction" {
				system, e := systemDirectory()
				if e != nil {
					t.Fatal(e)
				}
				link := filepath.Join(t.TempDir(), "link")
				if e := makeJunction(system, link, filepath.Dir(source)); e != nil {
					t.Fatal(e)
				}
				if _, e := acquireTestSnapshot(filepath.Join(link, "state_5.sqlite"), filepath.Join(t.TempDir(), "private"), limit, nil, nil); e == nil {
					t.Fatal("ancestor junction accepted")
				}
				return
			}
			s := snapshotAcquire(t, source)
			if mode == "private-hardlink" {
				if e := os.Link(filepath.Join(s.Private, "state_5.sqlite"), filepath.Join(t.TempDir(), "alias")); e != nil {
					t.Fatal(e)
				}
			}
			if mode == "unknown-entry" {
				os.WriteFile(filepath.Join(s.Private, "unknown"), []byte("preserve"), 0600)
			}
			var held *os.File
			if mode == "cleanup-share" {
				entry, e := snapshotOpen(filepath.Join(s.Private, "state_5.sqlite"), false)
				if e != nil {
					t.Fatal(e)
				}
				held = entry.File
				defer held.Close()
			}
			if e := s.Close(true); e == nil || !s.Closed {
				t.Fatal("cleanup failure hidden or source handles retained", e)
			}
			if _, e := os.Stat(filepath.Join(s.Private, "state_5.sqlite")); e != nil {
				t.Fatal("failed cleanup removed known bytes", e)
			}
			t.Log("cleanup failed visibly; source handles drained; owned private bytes retained for attention")
		})
	}
}
func TestSnapshotMappingSharing(t *testing.T) {
	for _, writable := range []bool{false, true} {
		t.Run(fmt.Sprintf("writable=%t", writable), func(t *testing.T) {
			source := snapshotFixture(t, false)
			u, _ := syscall.UTF16PtrFromString(source)
			access, protect, viewAccess := uint32(syscall.GENERIC_READ), uintptr(2), uintptr(4)
			if writable {
				access, protect, viewAccess = syscall.GENERIC_READ|syscall.GENERIC_WRITE, 4, 2
			}
			h, e := syscall.CreateFile(u, access, 7, nil, syscall.OPEN_EXISTING, 0, 0)
			if e != nil {
				t.Fatal(e)
			}
			mapping, _, e := proc("CreateFileMappingW").Call(uintptr(h), 0, protect, 0, 0, 0)
			if mapping == 0 {
				syscall.CloseHandle(h)
				t.Fatal(e)
			}
			defer syscall.CloseHandle(syscall.Handle(mapping))
			view, _, e := proc("MapViewOfFile").Call(mapping, viewAccess, 0, 0, 0)
			if view == 0 {
				syscall.CloseHandle(h)
				t.Fatal(e)
			}
			defer proc("UnmapViewOfFile").Call(view)
			if e := syscall.CloseHandle(h); e != nil {
				t.Fatal(e)
			}
			s, e := acquireTestSnapshot(source, filepath.Join(t.TempDir(), "private"), limit, nil, nil)
			if writable {
				if e != nil {
					if !errors.Is(e, syscall.Errno(32)) {
						t.Fatal("unexpected mapped-writer rejection", e)
					}
					t.Log("writable mapping rejected with sharing violation after backing handle closed")
					return
				}
				// Observe, rather than assert an unproved mapping exclusion rule.
				b := []byte{0xff}
				proc("RtlMoveMemory").Call(view+1000, uintptr(unsafe.Pointer(&b[0])), 1)
				if e := s.Verify(limit); e == nil {
					t.Fatal("mapped write escaped verification")
				}
				t.Log("LIMITATION: writable mapping coexisted; mapped mutation detected, acquisition does not exclude all writers")
			} else if e != nil {
				t.Fatal("read-only mapping rejected", e)
			}
			if e := s.Close(true); e != nil {
				t.Fatal(e)
			}
		})
	}
}

func TestSnapshotExistingWriterAndSQLiteHandoff(t *testing.T) {
	source := snapshotFixture(t, false)
	u, _ := syscall.UTF16PtrFromString(source)
	writer, e := syscall.CreateFile(u, syscall.GENERIC_WRITE, 7, nil, syscall.OPEN_EXISTING, 0, 0)
	if e != nil {
		t.Fatal(e)
	}
	_, acquireErr := acquireTestSnapshot(source, filepath.Join(t.TempDir(), "private"), limit, nil, nil)
	if e := syscall.CloseHandle(writer); e != nil {
		t.Fatal(e)
	}
	if !errors.Is(acquireErr, syscall.Errno(32)) {
		t.Fatal("existing writer did not fail without fallback", acquireErr)
	}
	s := snapshotAcquire(t, source)
	system, e := systemDirectory()
	if e != nil {
		t.Fatal(e)
	}
	dll, e := syscall.LoadDLL(filepath.Join(system, "winsqlite3.dll"))
	if e != nil {
		t.Fatal(e)
	}
	defer dll.Release()
	openSourceWithoutSQL := func() uintptr {
		var db uintptr
		b := append([]byte(source), 0)
		r, _, _ := dll.MustFindProc("sqlite3_open_v2").Call(uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(&db)), 6, 0)
		if db != 0 {
			rc, _, _ := dll.MustFindProc("sqlite3_close").Call(db)
			if rc != 0 {
				t.Fatal("source fixture SQLite drain", rc)
			}
		}
		return r
	}
	before, _ := dbHashes(source)
	heldRC := openSourceWithoutSQL()
	if heldRC == 0 {
		t.Fatal("writable SQLite entered while raw READ/shareREAD held")
	}
	after, _ := dbHashes(source)
	if string(encoded(before)) != string(encoded(after)) {
		t.Fatal("failed writable open changed source main/WAL")
	}
	if e := s.Verify(limit); e != nil {
		t.Fatal(e)
	}
	if e := s.Close(true); e != nil {
		t.Fatal(e)
	}
	releasedRC := openSourceWithoutSQL()
	if releasedRC != 0 {
		t.Fatal("writable SQLite fixture could not open after release", releasedRC)
	}
	t.Logf("owned source fixture only, SQL statements=0: writable SQLite open held rc=%d, released rc=%d; source/share lease cannot span writable activation", heldRC, releasedRC)
}
