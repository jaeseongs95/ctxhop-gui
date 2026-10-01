//go:build windows

package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// Internal shape validation only. Provider descriptors still require the
// canonical Config/SqliteConfig/extension binding before production admission.
var storeSpecs = [...]struct{ Kind, Filename string }{
	{"state", "state_5.sqlite"}, {"logs", "logs_2.sqlite"},
	{"goals", "goals_1.sqlite"}, {"memories", "memories_1.sqlite"},
	{"memoriesV2", "memories_v2_1.sqlite"}, {"queue", "queue_1.sqlite"},
	{"threadHistory", "thread_history_1.sqlite"}, {"agentMessageBoard", "agent_message_board_1.sqlite"},
}

type storeTarget struct{ Kind, Path string }
type storeSlot struct {
	Kind    string
	Present bool
	Data    *dbAcquisition
}
type storeAcquisition struct {
	ID, SourceRoot, PrivateRoot, SID                   string
	Source, Private                                    *dbAcquisition // root/ancestor anchors
	SourceDir, PrivateDir                              syscall.ByHandleFileInformation
	Stores                                             []storeSlot
	targets                                            []storeTarget
	Max                                                int64
	Pinned, PrivateCreated, PrivatePrepared, Finalized bool
	Draining, releasing, Closed, PrivateRemoved        bool
	CloseErr                                           error
}

func pinStoreSources(root string, targets []storeTarget, max int64) (s *storeAcquisition, retErr error) {
	s = &storeAcquisition{ID: nonce(), SourceRoot: filepath.Clean(root), Max: max, Source: &dbAcquisition{Files: map[string]snapshotEntry{}}}
	defer func() {
		if retErr != nil {
			retErr = errors.Join(retErr, s.Close(false))
		}
	}()
	if !filepath.IsAbs(root) || max < 100 || max > limit || len(targets) != len(storeSpecs) {
		return s, fmt.Errorf("store set root/target count/budget rejected")
	}
	for i, target := range targets {
		if target.Kind != storeSpecs[i].Kind || !samePath(target.Path, filepath.Join(root, storeSpecs[i].Filename)) {
			return s, fmt.Errorf("store set target order/canonical path rejected")
		}
	}
	s.targets = append([]storeTarget(nil), targets...)
	if e := s.Source.lockDirs(s.SourceRoot); e != nil {
		return s, e
	}
	s.SourceDir = s.Source.Dirs[len(s.Source.Dirs)-1].Info
	for i, spec := range storeSpecs {
		data := &dbAcquisition{Source: filepath.Join(s.SourceRoot, spec.Filename), ID: s.ID, SourceDir: s.SourceDir, Files: map[string]snapshotEntry{}, Copies: map[string]syscall.ByHandleFileInformation{}, Aggregate: s}
		s.Stores = append(s.Stores, storeSlot{Kind: spec.Kind, Data: data})
		if e := data.pinSourceFiles(max, i != 0); e != nil {
			return s, e
		}
		s.Stores[i].Present = len(data.Files) != 0
	}
	if e := s.checkSourceNamespace(); e != nil {
		return s, e
	}
	if e := s.checkBudgetAndIdentities(); e != nil {
		return s, e
	}
	s.Pinned = true
	return s, nil // all sources are still unread, including SHM
}

func acquireStoreSet(root, private string, targets []storeTarget, max int64, hook func(string) error, copyBytes func(io.Writer, io.Reader) (int64, error)) (s *storeAcquisition, retErr error) {
	s, retErr = pinStoreSources(root, targets, max)
	if retErr != nil {
		return s, retErr
	}
	defer func() {
		if retErr != nil {
			retErr = errors.Join(retErr, s.Close(true))
		}
	}()
	if hook != nil {
		if e := hook("pinned"); e != nil {
			return s, e
		}
	}
	return s, s.finalizePrivate(private, hook, copyBytes)
}

func (s *storeAcquisition) finalizePrivate(private string, hook func(string) error, copyBytes func(io.Writer, io.Reader) (int64, error)) error {
	if !s.Pinned || s.Closed || s.Draining || s.PrivateCreated || s.Finalized || !filepath.IsAbs(private) || within(s.SourceRoot, private) || within(private, s.SourceRoot) {
		return fmt.Errorf("store set private phase/path rejected")
	}
	if e := s.verifySourceMetadata(); e != nil {
		return e
	}
	s.PrivateRoot = filepath.Clean(private)
	s.Private = &dbAcquisition{Files: map[string]snapshotEntry{}}
	if e := s.Private.lockDirs(filepath.Dir(s.PrivateRoot)); e != nil {
		return e
	}
	entry, sid, created, e := createSnapshotDirectory(s.PrivateRoot)
	s.SID, s.PrivateCreated = sid, created
	if entry.File != nil {
		s.Private.Dirs = append(s.Private.Dirs, entry)
		s.PrivateDir = entry.Info
	}
	if e != nil {
		return e
	}
	for _, slot := range s.Stores {
		if slot.Present {
			if e := slot.Data.createPrivateDirectory(filepath.Join(s.PrivateRoot, slot.Kind)); e != nil {
				return e
			}
			if slot.Data.SID != s.SID {
				return fmt.Errorf("store set private SID mismatch")
			}
		}
	}
	if e := s.checkPrivateRoot(); e != nil {
		return e
	}
	if e := s.checkBudgetAndIdentities(); e != nil {
		return e
	}
	s.PrivatePrepared = true
	if hook != nil {
		if e := hook("private"); e != nil {
			return e
		}
	}
	if e := s.verifySourceMetadata(); e != nil {
		return e
	}
	if e := s.checkPrivateRoot(); e != nil {
		return e
	}
	for _, slot := range s.Stores {
		if slot.Present {
			entries, e := os.ReadDir(slot.Data.Private)
			if e != nil || len(entries) != 0 {
				return fmt.Errorf("store set private namespace not empty before copy: %v", e)
			}
		}
	}
	// No SQLite reader becomes eligible while only a subset is finalized.
	for _, slot := range s.Stores {
		if slot.Present {
			if e := slot.Data.finalizeCopy(s.Max, copyBytes); e != nil {
				return e
			}
		}
	}
	if hook != nil {
		if e := hook("copied"); e != nil {
			return e
		}
	}
	s.Finalized = true
	if e := s.Verify(); e != nil {
		s.Finalized = false
		return e
	}
	return nil
}

func (s *storeAcquisition) checkSourceNamespace() error {
	allowed := map[string]bool{}
	for _, spec := range storeSpecs {
		for _, suffix := range []string{"", "-wal", "-shm", "-journal"} {
			allowed[spec.Filename+suffix] = true
		}
	}
	entries, e := os.ReadDir(s.SourceRoot)
	if e != nil {
		return e
	}
	for _, entry := range entries {
		name := strings.ToLower(entry.Name())
		if strings.Contains(name, ".sqlite") && (!allowed[name] || entry.IsDir()) {
			return fmt.Errorf("store set unknown source DB namespace")
		}
	}
	return nil
}

func (s *storeAcquisition) checkBudgetAndIdentities() error {
	seen := map[string]bool{snapshotFileID(s.SourceDir): true}
	add := func(info syscall.ByHandleFileInformation) error {
		id := snapshotFileID(info)
		if seen[id] {
			return fmt.Errorf("store set file/directory identity alias")
		}
		seen[id] = true
		return nil
	}
	if s.PrivateCreated {
		if e := add(s.PrivateDir); e != nil {
			return e
		}
	}
	var total int64
	for _, slot := range s.Stores {
		if !snapshotIdentity(slot.Data.SourceDir, s.SourceDir) {
			return fmt.Errorf("store set source directory identity mismatch")
		}
		n, e := slot.Data.sourceBytes(s.Max)
		if e != nil || n > s.Max-total {
			return fmt.Errorf("store set aggregate byte budget rejected: %v", e)
		}
		total += n
		for _, entry := range slot.Data.Files {
			if e := add(entry.Info); e != nil {
				return e
			}
		}
		if slot.Data.PrivateCreated {
			if e := add(slot.Data.PrivateDir); e != nil {
				return e
			}
			for _, info := range slot.Data.Copies {
				if e := add(info); e != nil {
					return e
				}
			}
		}
	}
	return nil
}

func (s *storeAcquisition) verifySourceMetadata() error {
	if !s.Pinned || s.Closed || len(s.Stores) != len(storeSpecs) || s.Source.Closed {
		return fmt.Errorf("store set sources not pinned")
	}
	if len(s.Source.Dirs) == 0 {
		return fmt.Errorf("store set source root not held")
	}
	root := s.Source.Dirs[len(s.Source.Dirs)-1]
	if root.File == nil || !snapshotIdentity(root.Info, s.SourceDir) || !samePath(root.File.Name(), s.SourceRoot) {
		return fmt.Errorf("store set source root identity changed")
	}
	for _, entry := range s.Source.Dirs {
		if entry.File == nil {
			return fmt.Errorf("store set source ancestor not held")
		}
	}
	if e := verifySnapshotDirectories(s.Source.Dirs); e != nil {
		return e
	}
	for i, slot := range s.Stores {
		if slot.Kind != storeSpecs[i].Kind || !samePath(slot.Data.Source, filepath.Join(s.SourceRoot, storeSpecs[i].Filename)) || slot.Data.Aggregate != s || slot.Data.ID != s.ID || slot.Present != (len(slot.Data.Files) != 0) {
			return fmt.Errorf("store set descriptor/presence/binding changed")
		}
		if e := slot.Data.verifySourceMetadata(s.Max); e != nil {
			return e
		}
	}
	if e := s.checkSourceNamespace(); e != nil {
		return e
	}
	return s.checkBudgetAndIdentities()
}

func (s *storeAcquisition) checkPrivateRoot() error {
	if !s.PrivateCreated || s.PrivateRemoved || s.Private == nil || s.Private.Closed || len(s.Private.Dirs) == 0 {
		return fmt.Errorf("store set private root not held")
	}
	root := s.Private.Dirs[len(s.Private.Dirs)-1]
	if root.File == nil || !snapshotIdentity(root.Info, s.PrivateDir) || !samePath(root.File.Name(), s.PrivateRoot) {
		return fmt.Errorf("store set private root identity changed")
	}
	if e := verifySnapshotDirectories(s.Private.Dirs); e != nil {
		return e
	}
	if e := snapshotACL(s.PrivateRoot, s.SID); e != nil {
		return e
	}
	expected := map[string]bool{}
	for _, slot := range s.Stores {
		if slot.Data.PrivateCreated && !slot.Data.PrivateRemoved {
			if !slot.Present || !samePath(slot.Data.Private, filepath.Join(s.PrivateRoot, slot.Kind)) || slot.Data.SID != s.SID {
				return fmt.Errorf("store set private kind binding mismatch")
			}
			if e := verifySnapshotDirectories(slot.Data.Dirs); e != nil {
				return e
			}
			if e := snapshotACL(slot.Data.Private, s.SID); e != nil {
				return e
			}
			// Structural preflight permits generated sidecars before registration.
			// VerifyPrivate validates their ACL/size/identity before cleanup uses them.
			if len(slot.Data.Dirs) == 0 {
				return fmt.Errorf("store set private kind not held")
			}
			kindRoot := slot.Data.Dirs[len(slot.Data.Dirs)-1]
			if kindRoot.File == nil || !samePath(kindRoot.File.Name(), slot.Data.Private) || !snapshotIdentity(kindRoot.Info, slot.Data.PrivateDir) {
				return fmt.Errorf("store set private kind identity not held")
			}
			entries, e := os.ReadDir(slot.Data.Private)
			if e != nil {
				return e
			}
			base := filepath.Base(slot.Data.Source)
			for _, entry := range entries {
				name := entry.Name()
				if entry.IsDir() || name != base && name != base+"-wal" && name != base+"-shm" {
					return fmt.Errorf("store set private kind unknown entry")
				}
			}
			expected[slot.Kind] = true
		}
	}
	entries, e := os.ReadDir(s.PrivateRoot)
	if e != nil {
		return e
	}
	for _, entry := range entries {
		if !expected[entry.Name()] || !entry.IsDir() {
			return fmt.Errorf("store set private root unknown entry")
		}
		delete(expected, entry.Name())
	}
	if len(expected) != 0 {
		return fmt.Errorf("store set private kind missing")
	}
	return nil
}

func (s *storeAcquisition) Verify() error {
	if !s.Finalized || s.Closed || s.Draining {
		return fmt.Errorf("store set copies not finalized or draining")
	}
	if e := s.verifySourceMetadata(); e != nil {
		return e
	}
	if e := s.checkPrivateRoot(); e != nil {
		return e
	}
	for _, slot := range s.Stores {
		if slot.Present {
			if e := slot.Data.VerifyPrivate(); e != nil {
				return e
			}
		}
	}
	// Register every permitted new sidecar before the whole identity preflight.
	for _, slot := range s.Stores {
		if slot.Present {
			if _, _, e := slot.Data.checkPrivateCleanup(); e != nil {
				return e
			}
		}
	}
	return s.checkBudgetAndIdentities()
}

func (s *storeAcquisition) Observation() (object, error) {
	if e := s.Verify(); e != nil {
		return nil, e
	}
	stores := []any{}
	for _, slot := range s.Stores {
		var acquisition any
		if slot.Present {
			acquisition = slot.Data.acquisitionObservation()
		}
		stores = append(stores, object{"kind": slot.Kind, "dbPath": slot.Data.Source, "present": slot.Present, "acquisition": acquisition})
	}
	return object{"schemaVersion": 2, "acquisitionId": s.ID,
		"sourceRoot":  object{"directory": s.SourceRoot, "directoryIdentity": snapshotFileID(s.SourceDir)},
		"privateRoot": object{"directory": s.PrivateRoot, "directoryIdentity": snapshotFileID(s.PrivateDir)}, "stores": stores}, nil
}

func (s *storeAcquisition) CleanupPrivate() error {
	if s.Closed {
		return fmt.Errorf("store set cleanup after source release")
	}
	if s.PrivateRemoved {
		return nil
	}
	s.Draining = true // stop new readers before any cleanup preflight
	if e := s.checkPrivateRoot(); e != nil {
		return e
	}
	if e := s.checkBudgetAndIdentities(); e != nil {
		return e
	}
	// Unknown names/identities in the last kind must preserve earlier kinds too.
	for _, slot := range s.Stores {
		if slot.Data.PrivateCreated && !slot.Data.PrivateRemoved {
			if _, _, e := slot.Data.checkPrivateCleanup(); e != nil {
				return e
			}
		}
	}
	for _, slot := range s.Stores {
		if slot.Data.PrivateCreated && !slot.Data.PrivateRemoved {
			if e := slot.Data.CleanupPrivate(); e != nil {
				return e
			}
		}
	}
	index := len(s.Private.Dirs) - 1
	if e := s.Private.Dirs[index].File.Close(); e != nil {
		return e
	}
	s.Private.Dirs[index].File = nil
	if e := os.Remove(s.PrivateRoot); e != nil {
		return e
	}
	s.PrivateRemoved = true
	return nil
}

// clean=true requires all Go/provider private readers to have explicitly drained.
// Unknown reader completion uses false, retaining the whole private namespace.
func (s *storeAcquisition) Close(clean bool) error {
	if s.Closed {
		return s.CloseErr
	}
	s.Draining = true
	if clean && s.PrivateCreated {
		s.CloseErr = errors.Join(s.CloseErr, s.CleanupPrivate())
	}
	s.releasing = true
	for _, slot := range s.Stores {
		s.CloseErr = errors.Join(s.CloseErr, slot.Data.releaseLeases())
	}
	s.CloseErr = errors.Join(s.CloseErr, s.Source.releaseLeases())
	if s.Private != nil {
		s.CloseErr = errors.Join(s.CloseErr, s.Private.releaseLeases())
	}
	s.Closed = true
	return s.CloseErr
}

func (s *storeAcquisition) VerifyReleasedSources(hook func() error) (retErr error) {
	if !s.Finalized || !s.Closed || s.CloseErr != nil || !s.PrivateRemoved {
		return fmt.Errorf("store set freshness before successful cleanup/drain")
	}
	fresh, e := pinStoreSources(s.SourceRoot, s.targets, s.Max)
	if e != nil {
		return e
	}
	defer func() { retErr = errors.Join(retErr, fresh.Close(false)) }()
	if !snapshotIdentity(fresh.SourceDir, s.SourceDir) {
		return fmt.Errorf("store set source root changed after release")
	}
	// First compare the whole metadata vector before measuring any source byte.
	for i, slot := range s.Stores {
		current := fresh.Stores[i]
		if slot.Present != current.Present || len(slot.Data.Files) != len(current.Data.Files) {
			return fmt.Errorf("store set source presence changed after release")
		}
		for name, expected := range slot.Data.Files {
			entry, exists := current.Data.Files[name]
			if !exists || !snapshotIdentity(entry.Info, expected.Info) || snapshotSize(entry.Info) != snapshotSize(expected.Info) {
				return fmt.Errorf("store set source identity/size changed after release")
			}
			entry.Hash = expected.Hash
			current.Data.Files[name] = entry
		}
	}
	if hook != nil {
		if e := hook(); e != nil {
			return e
		}
	}
	for _, slot := range fresh.Stores {
		if e := slot.Data.verifySourceBytes(s.Max); e != nil {
			return e
		}
	}
	return nil
}
