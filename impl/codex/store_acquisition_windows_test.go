//go:build windows

package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// Raw copy fixtures have no auxiliary schema claim and open no SQLite reader.
func storeFixture(t *testing.T, all bool) (string, []storeTarget) {
	t.Helper()
	home := t.TempDir()
	targets := []storeTarget{}
	for i, spec := range storeSpecs {
		path := filepath.Join(home, spec.Filename)
		targets = append(targets, storeTarget{spec.Kind, path})
		if all || i == 0 {
			for _, suffix := range []string{"", "-wal", "-shm"} {
				b := make([]byte, 128+i)
				b[0] = byte(i + 1)
				if e := createFile(path+suffix, b); e != nil {
					t.Fatal(e)
				}
			}
		}
	}
	return home, targets
}

func storeWriterAllowed(t *testing.T, path string) {
	t.Helper()
	f, e := os.OpenFile(path, os.O_WRONLY, 0)
	if e != nil {
		t.Fatal("source lease did not drain", e)
	}
	if e := f.Close(); e != nil {
		t.Fatal(e)
	}
}

func TestStoreSetBarriersObservationAndFreshness(t *testing.T) {
	home, targets := storeFixture(t, true)
	s, e := pinStoreSources(home, targets, limit)
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
	for _, slot := range s.Stores {
		assertSnapshotPinUnread(t, slot.Data)
		if len(slot.Data.Dirs) != 0 || !snapshotIdentity(slot.Data.SourceDir, s.SourceDir) {
			t.Fatal("slot duplicates shared source anchors")
		}
		if e := slot.Data.releaseLeases(); e == nil {
			t.Fatal("member released aggregate source")
		}
	}
	if _, e := s.Observation(); e == nil {
		t.Fatal("pin approved as completed observation")
	}
	private := filepath.Join(t.TempDir(), "private")
	copies := 0
	e = s.finalizePrivate(private, func(phase string) error {
		if phase == "private" {
			for _, slot := range s.Stores {
				assertSnapshotPinUnread(t, slot.Data)
				entries, e := os.ReadDir(slot.Data.Private)
				if e != nil || len(entries) != 0 || len(slot.Data.Dirs) != 1 {
					t.Fatal("private barrier wrote bytes or duplicates anchors", e)
				}
			}
		}
		if phase == "copied" {
			for _, slot := range s.Stores {
				if !slot.Data.Finalized || slot.Data.privateCopyReady() {
					t.Fatal("subset/whole copied phase opened reader gate")
				}
			}
			if _, e := inspectPrivateState(s.Stores[0].Data, nil); e == nil {
				t.Fatal("SQLite before aggregate finalization")
			}
		}
		return nil
	}, func(w io.Writer, r io.Reader) (int64, error) {
		copies++
		if !s.PrivatePrepared || s.Finalized {
			t.Fatal("invalid aggregate copy phase")
		}
		for _, slot := range s.Stores {
			for name := range slot.Data.Files {
				assertSnapshotWriterDenied(t, filepath.Join(home, name))
			}
		}
		if _, e := inspectPrivateState(s.Stores[0].Data, nil); e == nil {
			t.Fatal("partial finalized subset approved for SQLite")
		}
		return io.Copy(w, r)
	})
	if e != nil || copies != 16 {
		t.Fatal("aggregate copy/finalize", copies, e)
	}
	obs, e := s.Observation()
	if e != nil || obs["schemaVersion"] != 2 || obs["acquisitionId"] != s.ID {
		t.Fatal("v2 observation binding", e)
	}
	if len(obs) != 5 || len(obs["stores"].([]any)) != 8 {
		t.Fatal("outer hash duplication or missing stores")
	}
	for _, item := range obs["stores"].([]any) {
		acq := item.(object)["acquisition"].(object)
		if acq["acquisitionId"] != s.ID || acq["source"].(object)["directoryIdentity"] != snapshotFileID(s.SourceDir) {
			t.Fatal("nested aggregate identity mismatch")
		}
	}
	// An already-completed v1 projection must not promote an internal v2 group.
	provider := &session{Projection: object{"inputComplete": true}}
	if e := provider.complete(dbView{Acquisition: s.Stores[0].Data}); e == nil {
		t.Fatal("production v1 complete accepted internal v2")
	}
	if e := s.CleanupPrivate(); e != nil {
		t.Fatal(e)
	}
	for _, slot := range s.Stores {
		assertSnapshotWriterDenied(t, slot.Data.Source)
	}
	if e := s.Close(false); e != nil {
		t.Fatal(e)
	}
	freshRuns := 0
	if e := s.VerifyReleasedSources(func() error {
		freshRuns++
		for _, spec := range storeSpecs {
			for _, suffix := range []string{"", "-wal", "-shm"} {
				assertSnapshotWriterDenied(t, filepath.Join(home, spec.Filename)+suffix)
			}
		}
		return nil
	}); e != nil || freshRuns != 1 {
		t.Fatal("fresh all-store barrier", e)
	}
	for _, slot := range s.Stores {
		storeWriterAllowed(t, slot.Data.Source)
	}
	if e := os.WriteFile(targets[7].Path, make([]byte, 135), 0600); e != nil {
		t.Fatal(e)
	}
	if e := s.VerifyReleasedSources(nil); e == nil {
		t.Fatal("same-size source changed after release accepted")
	}
}

func TestStoreSetAbsentAndDescriptorFailures(t *testing.T) {
	for _, variant := range []string{"state-missing", "orphan-wal", "orphan-shm", "orphan-journal", "unknown-db", "order", "count", "parent", "last-writer", "aggregate-budget", "hardlink"} {
		t.Run(variant, func(t *testing.T) {
			home, targets := storeFixture(t, false)
			max := limit
			switch variant {
			case "state-missing":
				if e := os.Remove(targets[0].Path); e != nil {
					t.Fatal(e)
				}
			case "orphan-wal", "orphan-shm", "orphan-journal":
				suffix := map[string]string{"orphan-wal": "-wal", "orphan-shm": "-shm", "orphan-journal": "-journal"}[variant]
				if e := createFile(targets[7].Path+suffix, []byte{1}); e != nil {
					t.Fatal(e)
				}
			case "unknown-db":
				if e := createFile(filepath.Join(home, "future.sqlite-wal"), []byte{1}); e != nil {
					t.Fatal(e)
				}
			case "order":
				targets[6], targets[7] = targets[7], targets[6]
			case "count":
				targets = targets[:7]
			case "parent":
				targets[7].Path = filepath.Join(t.TempDir(), storeSpecs[7].Filename)
			case "last-writer":
				if e := createFile(targets[7].Path, make([]byte, 128)); e != nil {
					t.Fatal(e)
				}
				writer, e := os.OpenFile(targets[7].Path, os.O_WRONLY, 0)
				if e != nil {
					t.Fatal(e)
				}
				defer writer.Close()
			case "aggregate-budget":
				max = 300
				if e := createFile(targets[7].Path, make([]byte, 128)); e != nil {
					t.Fatal(e)
				}
			case "hardlink":
				if e := os.Link(targets[0].Path, targets[7].Path); e != nil {
					t.Fatal(e)
				}
			}
			s, e := pinStoreSources(home, targets, max)
			if e == nil || !s.Closed || s.PrivateCreated {
				t.Fatal("bad descriptor/source accepted or leaked", e)
			}
			for _, slot := range s.Stores {
				if len(slot.Data.Copies) != 0 || slot.Data.PrivateCreated {
					t.Fatal("pin failure copied bytes")
				}
				for _, file := range slot.Data.Files {
					if file.Hash != "" {
						t.Fatal("pin failure measured bytes")
					}
				}
			}
			if variant != "hardlink" && variant != "state-missing" {
				storeWriterAllowed(t, filepath.Join(home, storeSpecs[0].Filename))
			}
		})
	}
	t.Run("absent-four-names", func(t *testing.T) {
		home, targets := storeFixture(t, false)
		s, e := acquireStoreSet(home, filepath.Join(t.TempDir(), "private"), targets, limit, nil, nil)
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
		obs, e := s.Observation()
		if e != nil {
			t.Fatal(e)
		}
		for i, item := range obs["stores"].([]any) {
			if i != 0 && (item.(object)["present"] != false || item.(object)["acquisition"] != nil || s.Stores[i].Data.PrivateCreated) {
				t.Fatal("absent store has private/nested acquisition")
			}
		}
		if e := createFile(targets[7].Path+"-shm", []byte{1}); e != nil {
			t.Fatal(e)
		}
		if e := s.Verify(); e == nil {
			t.Fatal("absent name changed while source root held")
		}
		if e := os.Remove(targets[7].Path + "-shm"); e != nil {
			t.Fatal(e)
		}
		if e := s.Close(true); e != nil {
			t.Fatal(e)
		}
		if e := createFile(targets[7].Path, make([]byte, 128)); e != nil {
			t.Fatal(e)
		}
		if e := s.VerifyReleasedSources(nil); e == nil {
			t.Fatal("fresh source presence change accepted")
		}
	})
}

func TestStoreSetWholeCleanupAndPartialCopyFailure(t *testing.T) {
	t.Run("unknown-last-kind-preserves-first", func(t *testing.T) {
		home, targets := storeFixture(t, true)
		private := filepath.Join(t.TempDir(), "private")
		s, e := acquireStoreSet(home, private, targets, limit, nil, nil)
		if e != nil {
			t.Fatal(e)
		}
		unknown := filepath.Join(s.Stores[7].Data.Private, "unknown")
		if e := createFile(unknown, []byte{1}); e != nil {
			t.Fatal(e)
		}
		if e := s.CleanupPrivate(); e == nil {
			t.Fatal("unknown last namespace approved")
		}
		for _, slot := range s.Stores {
			if _, e := os.Stat(filepath.Join(slot.Data.Private, filepath.Base(slot.Data.Source))); e != nil {
				t.Fatal("preflight deleted an earlier copy", e)
			}
			assertSnapshotWriterDenied(t, slot.Data.Source)
		}
		if e := s.Close(true); e == nil || !s.Closed || s.PrivateRemoved {
			t.Fatal("attention cleanup error hidden", e)
		}
		if _, e := os.Stat(unknown); e != nil {
			t.Fatal("unknown file removed", e)
		}
		for _, slot := range s.Stores {
			storeWriterAllowed(t, slot.Data.Source)
		}
		if e := s.VerifyReleasedSources(nil); e == nil {
			t.Fatal("failed cleanup approved as fresh")
		}
	})
	t.Run("partial-copy-retains-all-source-until-cleanup", func(t *testing.T) {
		home, targets := storeFixture(t, true)
		s, e := pinStoreSources(home, targets, limit)
		if e != nil {
			t.Fatal(e)
		}
		calls := 0
		sentinel := errors.New("owned partial-copy failure")
		e = s.finalizePrivate(filepath.Join(t.TempDir(), "private"), nil, func(w io.Writer, r io.Reader) (int64, error) {
			calls++
			if calls == 15 {
				n, e := io.CopyN(w, r, 1)
				return n, errors.Join(sentinel, e)
			}
			return io.Copy(w, r)
		})
		if !errors.Is(e, sentinel) || s.Finalized || s.Closed {
			t.Fatal("partial copy promoted or source released", e)
		}
		for _, slot := range s.Stores {
			assertSnapshotWriterDenied(t, slot.Data.Source)
		}
		if e := s.Close(true); e != nil || !s.PrivateRemoved {
			t.Fatal("owned partial copies did not clean/drain", e)
		}
		for _, slot := range s.Stores {
			storeWriterAllowed(t, slot.Data.Source)
		}
	})
	t.Run("last-kind-unknown-before-first-byte", func(t *testing.T) {
		home, targets := storeFixture(t, true)
		private := filepath.Join(t.TempDir(), "private")
		copies := 0
		s, e := acquireStoreSet(home, private, targets, limit, func(phase string) error {
			if phase == "private" {
				return createFile(filepath.Join(private, storeSpecs[7].Kind, "unknown"), []byte{1})
			}
			return nil
		}, func(w io.Writer, r io.Reader) (int64, error) { copies++; return io.Copy(w, r) })
		if e == nil || copies != 0 || !s.Closed || s.PrivateRemoved {
			t.Fatal("private barrier failed", copies, e)
		}
		for _, slot := range s.Stores {
			for _, file := range slot.Data.Files {
				if file.Hash != "" {
					t.Fatal("hash before whole private validation")
				}
			}
		}
	})
}

func TestStoreSetMetadataIdentityAndBudget(t *testing.T) {
	home, targets := storeFixture(t, true)
	s, e := pinStoreSources(home, targets, limit)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close(false)
	base := storeSpecs[7].Filename
	original := s.Stores[7].Data.Files[base]
	alias := original
	alias.Info = s.Stores[0].Data.Files[storeSpecs[0].Filename].Info
	s.Stores[7].Data.Files[base] = alias
	if e := s.checkBudgetAndIdentities(); e == nil {
		t.Fatal("cross-store identity alias accepted")
	}
	s.Stores[7].Data.Files[base] = original
	small := s.Stores[0].Data.Files[storeSpecs[0].Filename]
	large := small
	large.Info.FileSizeHigh = uint32(uint64(limit) >> 32)
	large.Info.FileSizeLow = uint32(limit)
	s.Stores[0].Data.Files[storeSpecs[0].Filename] = large
	if e := s.checkBudgetAndIdentities(); e == nil {
		t.Fatal("aggregate budget double/overflow accepted")
	}
	s.Stores[0].Data.Files[storeSpecs[0].Filename] = small
	for _, slot := range s.Stores {
		assertSnapshotPinUnread(t, slot.Data)
	}
	// Nilling a captured root anchor cannot be treated as a live source lease.
	index := len(s.Source.Dirs) - 1
	root := s.Source.Dirs[index]
	s.Source.Dirs[index].File = nil
	if e := s.verifySourceMetadata(); e == nil {
		t.Fatal("unheld source root accepted")
	}
	s.Source.Dirs[index] = root
}
