//go:build windows

package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func assertSnapshotPinUnread(t *testing.T, s *dbAcquisition) {
	t.Helper()
	if !s.Pinned || s.Finalized || len(s.Copies) != 0 {
		t.Fatal("pin consumed/finalized bytes")
	}
	for name, entry := range s.Files {
		position, e := entry.File.Seek(0, io.SeekCurrent)
		if e != nil || position != 0 || entry.Hash != "" {
			t.Fatal("pin read/hash before full source barrier", name, position, e)
		}
	}
}

func assertSnapshotWriterDenied(t *testing.T, path string) {
	t.Helper()
	u, e := syscall.UTF16PtrFromString(path)
	if e != nil {
		t.Fatal(e)
	}
	h, e := syscall.CreateFile(u, syscall.GENERIC_WRITE, 7, nil, syscall.OPEN_EXISTING, 0, 0)
	if e == nil {
		syscall.CloseHandle(h)
		t.Fatal("writer entered before whole lease release", path)
	}
	if e != syscall.Errno(32) {
		t.Fatal("unexpected writer rejection", path, e)
	}
}

func TestSnapshotPinAndFinalizePhases(t *testing.T) {
	source := snapshotFixture(t, false)
	if e := createFile(source+"-shm", []byte("owned source SHM; pin must not hash it")); e != nil {
		t.Fatal(e)
	}
	s, e := pinSnapshotSource(source, limit)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		if e := s.Close(true); e != nil {
			t.Error(e)
		}
	})
	assertSnapshotPinUnread(t, s)
	if _, e := s.Observation(); e == nil {
		t.Fatal("pinned source approved as finalized observation")
	}
	if _, e := inspectPrivateState(s, nil); e == nil {
		t.Fatal("SQLite inspection approved before private finalization")
	}
	if e := s.VerifyPrivate(); e == nil {
		t.Fatal("private verification approved before creation")
	}
	if e := s.finalizeCopy(limit, nil); e == nil {
		t.Fatal("finalize approved before private creation")
	}
	private := filepath.Join(t.TempDir(), "private")
	if e := s.createPrivate(private); e != nil {
		t.Fatal(e)
	}
	entries, e := os.ReadDir(private)
	if e != nil || len(entries) != 0 {
		t.Fatal("private metadata phase wrote bytes", e)
	}
	if _, e := s.Observation(); e == nil {
		t.Fatal("empty private directory approved as finalized copy")
	}
	if _, e := inspectPrivateState(s, nil); e == nil {
		t.Fatal("SQLite inspection approved before byte finalization")
	}
	assertSnapshotPinUnread(t, s)
	if e := s.finalizeCopy(limit, nil); e != nil {
		t.Fatal(e)
	}
	if !s.Finalized || s.Files["state_5.sqlite-shm"].Hash == "" {
		t.Fatal("finalized source/SHM provenance missing")
	}
	if _, e := s.Observation(); e != nil {
		t.Fatal(e)
	}
	if e := s.finalizeCopy(limit, nil); e == nil {
		t.Fatal("finalized copy replay accepted")
	}
	if e := s.CleanupPrivate(); e != nil {
		t.Fatal(e)
	}
	assertSnapshotWriterDenied(t, source)
	if e := s.releaseLeases(); e != nil {
		t.Fatal(e)
	}
	if e := s.VerifyReleasedSource(); e != nil {
		t.Fatal(e)
	}
}

// Raw copy-only fixtures: no SQLite initializer/reader or engine is involved.
// The set owner pattern pins all eight sources before entering any byte phase.
func TestSnapshotEightSourceBarrierAndDrain(t *testing.T) {
	names := []string{"state_5.sqlite", "logs_2.sqlite", "goals_1.sqlite", "memories_1.sqlite", "memories_v2_1.sqlite", "queue_1.sqlite", "thread_history_1.sqlite", "agent_message_board_1.sqlite"}
	for _, lastWriter := range []bool{false, true} {
		name := "all-pinned-before-copy"
		if lastWriter {
			name = "last-pin-failure-before-any-byte"
		}
		t.Run(name, func(t *testing.T) {
			home, privateParent := t.TempDir(), t.TempDir()
			for i, base := range names {
				for _, suffix := range []string{"", "-wal", "-shm"} {
					b := make([]byte, 128+i)
					b[0] = byte(i + 1)
					if e := createFile(filepath.Join(home, base)+suffix, b); e != nil {
						t.Fatal(e)
					}
				}
			}
			if lastWriter {
				writer, e := os.OpenFile(filepath.Join(home, names[7]), os.O_WRONLY, 0)
				if e != nil {
					t.Fatal(e)
				}
				defer writer.Close()
			}
			var pinned []*dbAcquisition
			defer func() {
				for _, s := range pinned {
					if e := s.Close(true); e != nil {
						t.Error(e)
					}
				}
			}()
			for i, base := range names {
				s, e := pinSnapshotSource(filepath.Join(home, base), limit)
				if lastWriter && i == 7 {
					if !errors.Is(e, syscall.Errno(32)) || !s.Closed || len(s.Copies) != 0 || s.PrivateCreated {
						t.Fatal("last pin failure did not drain without copying", e)
					}
					for _, held := range pinned {
						assertSnapshotPinUnread(t, held)
						assertSnapshotWriterDenied(t, held.Source)
					}
					entries, e := os.ReadDir(privateParent)
					if e != nil || len(entries) != 0 {
						t.Fatal("pin failure entered private creation", e)
					}
					return
				}
				if e != nil {
					t.Fatal(e)
				}
				pinned = append(pinned, s)
				assertSnapshotPinUnread(t, s)
			}
			// Metadata-only budget preflight, before even private directories exist.
			var total int64
			for _, s := range pinned {
				n, e := s.sourceBytes(limit)
				if e != nil || n > limit-total {
					t.Fatal("aggregate metadata budget rejected", e)
				}
				total += n
				if !snapshotIdentity(s.SourceDir, pinned[0].SourceDir) {
					t.Fatal("canonical shared source directory identity mismatch")
				}
				if e := s.createPrivate(filepath.Join(privateParent, filepath.Base(s.Source))); e != nil {
					t.Fatal(e)
				}
				assertSnapshotPinUnread(t, s)
			}
			for _, s := range pinned {
				if e := s.finalizeCopy(limit, func(w io.Writer, r io.Reader) (int64, error) {
					for _, held := range pinned {
						for file := range held.Files {
							assertSnapshotWriterDenied(t, filepath.Join(home, file))
						}
					}
					return io.Copy(w, r)
				}); e != nil {
					t.Fatal(e)
				}
				if e := s.VerifyPrivate(); e != nil {
					t.Fatal(e)
				}
				if _, e := os.Stat(filepath.Join(s.Private, filepath.Base(s.Source)+"-shm")); !os.IsNotExist(e) {
					t.Fatal("raw source SHM copied into private namespace", e)
				}
			}
			for _, s := range pinned {
				if e := s.CleanupPrivate(); e != nil {
					t.Fatal(e)
				}
				for _, held := range pinned {
					assertSnapshotWriterDenied(t, held.Source)
				}
			}
			for _, s := range pinned {
				if e := s.releaseLeases(); e != nil {
					t.Fatal(e)
				}
			}
			t.Log("24 source handles pinned before first byte; 8 private copies finalized; whole cleanup before source lease release; SQLite/engine=0")
		})
	}
}

func TestSnapshotMetadataUnsignedBudget(t *testing.T) {
	for _, pair := range [][2]uint64{{uint64(limit), 0}, {uint64(limit), 1}, {^uint64(0), 1}, {1 << 63, 0}} {
		s := &dbAcquisition{Source: "state_5.sqlite", Files: map[string]snapshotEntry{}}
		for i, name := range []string{"state_5.sqlite", "state_5.sqlite-wal"} {
			s.Files[name] = snapshotEntry{Info: syscall.ByHandleFileInformation{FileSizeHigh: uint32(pair[i] >> 32), FileSizeLow: uint32(pair[i])}}
		}
		n, e := s.sourceBytes(limit)
		if pair[0] == uint64(limit) && pair[1] == 0 {
			if e != nil || n != limit {
				t.Fatal("exact metadata budget rejected", e, n)
			}
		} else if e == nil {
			t.Fatal("overflow/oversize metadata accepted", pair, n)
		}
	}
}
