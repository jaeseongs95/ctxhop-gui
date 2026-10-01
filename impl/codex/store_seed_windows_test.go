//go:build windows && ctxhop_store_seed

package main

import (
	"context"
	"flag"
	"path/filepath"
	"testing"
)

var canonicalStoreSeedHandoff = flag.String("ctxhop-store-seed-handoff", "", "frozen seed51 raw receipt; never opened with SQLite")

func TestStoreCanonicalSeedPrivateProof(t *testing.T) {
	b, e := readBounded(*canonicalStoreSeedHandoff, lineLimit)
	if e != nil || digest(b) != "712ac77321f1706b9892ba4b682f8950c2a9e77a2fc2666c7cfe3fac0b2259bc" {
		t.Fatal("canonical seed handoff missing/changed", e)
	}
	v, e := parseJSON(b)
	if e != nil {
		t.Fatal(e)
	}
	handoff := obj(v)
	slots := array(handoff["stores"])
	if len(slots) != 8 || handoff["seedId"] != "51c980db2f43438eb1a8ca838045fae2" {
		t.Fatal("unbound canonical8 seed")
	}
	home := filepath.Dir(text(obj(slots[0])["path"]))
	if !samePath(home, `D:\Go\codex-s4\schema-seeds\51c980db2f43438eb1a8ca838045fae2\sqlite`) {
		t.Fatal("unexpected immutable seed namespace")
	}
	targets := []storeTarget{}
	for i, spec := range storeSpecs {
		row := obj(slots[i])
		if row["kind"] != spec.Kind || !samePath(text(row["path"]), filepath.Join(home, spec.Filename)) {
			t.Fatal("canonical descriptor vector changed")
		}
		targets = append(targets, storeTarget{spec.Kind, text(row["path"])})
	}
	// All source main/absence handles are acquired before byte reads. Only the
	// new owned finalized private copies receive readonly SQLite connections.
	private := filepath.Join(t.TempDir(), "private")
	if *storeSeedReader != "" {
		if e := validateSeedHandoffOutput(*storeSeedOutput); e != nil {
			t.Fatal(e)
		}
		private = filepath.Join(*storeSeedOutput, "private")
	}
	s, e := acquireStoreSet(home, private, targets, limit, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	releaseAllowed := true
	defer func() {
		if releaseAllowed {
			if e := s.Close(false); e != nil {
				t.Error("source lease release", e)
			}
		}
	}()
	for i, slot := range s.Stores {
		if !slot.Present || slot.Data == nil {
			t.Fatal("canonical present store missing", slot.Kind)
		}
		file := obj(array(obj(slots[i])["files"])[0])
		entry := slot.Data.Files[storeSpecs[i].Filename]
		n, ok := integer(file["size"])
		if !slot.Present || !ok || n != snapshotSize(entry.Info) || file["identity"] != snapshotFileID(entry.Info) || file["sha256"] != entry.Hash {
			t.Fatal("canonical source metadata/hash changed", slot.Kind)
		}
	}
	observation, proof, e := inspectPrivateStoreProof(context.Background(), s, relationTargets(t))
	if e != nil || observation == nil || proof == nil || s.ReadersOpen != 0 {
		t.Fatal("canonical8 private schema/typed proof failed", e)
	}
	if *storeSeedReader != "" {
		var drained bool
		drained, e = handoffSeedSchema(s, observation, proof)
		releaseAllowed = drained
		if e != nil {
			t.Fatal("Rust handoff failed; private copies preserved", e)
		}
	}
	if e := s.Close(true); e != nil {
		t.Fatal("whole reader drain and owned cleanup", e)
	}
	if e := s.VerifyReleasedSources(nil); e != nil {
		t.Fatal("fresh source vector after cleanup/release", e)
	}
	if *storeSeedReader != "" {
		if e := createFile(filepath.Join(*storeSeedOutput, "go-release-receipt.json"), append(encoded(object{"schemaVersion": int64(2), "ownerSessionId": seedAcquisitionOwner, "acquisitionId": s.ID, "wholePrivateVerified": true, "privateRemoved": s.PrivateRemoved, "sourceLeasesReleased": s.Closed, "releasedSourcesFresh": true, "expectedCancellationPoint": *storeSeedCancelPoint, "completedProof": false, "originalSQLiteOpens": int64(0), "productionAdmission": "notRun"}), '\n')); e != nil {
			t.Fatal("release/freshness receipt", e)
		}
	}
	if *storeSeedCancelPoint != "" {
		t.Log("fixture token cancellation", *storeSeedCancelPoint, "; Rust success proof absent; whole Job/reader drain and owned cleanup/release freshness passed; original SQLite opens=0; no production callerDrop/OS cancellation/admission claim")
	} else {
		t.Log("canonical seed51 actual8 bytes -> fresh private readonly schema/typed proof; all reader drains and whole cleanup/freshness passed; original SQLite opens=0, protected engine executions=0; synthetic M-R-Q only, no production admission/approval")
	}
}
