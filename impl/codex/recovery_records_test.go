package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestExplicitResolveAllowsNextGoImportAndPreservesRecord(t *testing.T) {
	for _, corrupt := range []bool{false, true} {
		t.Run(map[bool]string{false: "valid", true: "invalid-json"}[corrupt], func(t *testing.T) {
			o, m := importFixture(t, "legacy", false)
			f := fixtureFamily("legacy")
			if e := support(f, o.Home); e != nil {
				t.Fatal(e)
			}
			run := runPath(o.Home, strings.Repeat("c", 32))
			if e := os.MkdirAll(run, 0700); e != nil {
				t.Fatal(e)
			}
			j := &journal{Version: 3, Impl: "ctxhop-codex", Status: "pending", Phase: "created", Home: o.Home, Cwd: o.Cwd, ID: rootID, Members: f.Members, ArchiveSHA256: strings.Repeat("a", 64)}
			if e := saveJournal(run, j, true); e != nil {
				t.Fatal(e)
			}
			live, resolved := filepath.Join(run, "journal.json"), filepath.Join(run, "journal.resolved.json")
			if corrupt {
				if e := os.WriteFile(live, []byte("unreadable JSON preserved by explicit resolve"), 0600); e != nil {
					t.Fatal(e)
				}
			}
			_, e := importArchive(o)
			assertCode(t, e, "pending_record")
			before, e := os.ReadFile(live)
			if e != nil {
				t.Fatal(e)
			}
			// The actual GUI resolve action is this no-replace rename, after the
			// user's displayed SHA has matched. The fixture models that closure.
			if e := moveFile(live, resolved, false); e != nil {
				t.Fatal(e)
			}
			r, e := importArchive(o)
			if e != nil || r["status"] != "imported" || m.Deletes != 0 {
				t.Fatal("closed record blocked next import", r, e)
			}
			after, e := os.ReadFile(resolved)
			if e != nil || !bytes.Equal(before, after) {
				t.Fatal("resolved bytes were consumed or changed", e)
			}
		})
	}
}

func TestRecoveryRecordUnknownAndUnsafeStillBlocks(t *testing.T) {
	for _, variant := range []string{"missing", "both", "invalid-name", "malformed", "unknown-status", "foreign-home", "directory", "hardlink", "oversize", "complete", "python-pending", "python-complete"} {
		t.Run(variant, func(t *testing.T) {
			home := t.TempDir()
			name := strings.Repeat("c", 32)
			if variant == "invalid-name" {
				name = "unknown-run"
			}
			run := runPath(home, name)
			if e := os.MkdirAll(run, 0700); e != nil {
				t.Fatal(e)
			}
			live, resolved := filepath.Join(run, "journal.json"), filepath.Join(run, "journal.resolved.json")
			f := fixtureFamily("legacy")
			if e := support(f, home); e != nil {
				t.Fatal(e)
			}
			j := &journal{Version: 3, Impl: "ctxhop-codex", Status: "complete", Phase: "verified", Home: home, Cwd: home, ID: rootID, Members: f.Members, ArchiveSHA256: strings.Repeat("a", 64)}
			if variant != "missing" {
				if e := saveJournal(run, j, true); e != nil {
					t.Fatal(e)
				}
			}
			switch variant {
			case "both":
				if e := createFile(resolved, []byte("closed")); e != nil {
					t.Fatal(e)
				}
			case "malformed":
				if e := os.WriteFile(live, []byte(`{"status":"complete"`), 0600); e != nil {
					t.Fatal(e)
				}
			case "unknown-status":
				j.Status = "future"
				if e := saveJournal(run, j, false); e != nil {
					t.Fatal(e)
				}
			case "foreign-home":
				j.Home = t.TempDir()
				if e := saveJournal(run, j, false); e != nil {
					t.Fatal(e)
				}
			case "directory":
				if e := os.Remove(live); e != nil {
					t.Fatal(e)
				}
				if e := os.Mkdir(resolved, 0700); e != nil {
					t.Fatal(e)
				}
			case "hardlink":
				if e := os.Rename(live, resolved); e != nil {
					t.Fatal(e)
				}
				if e := os.Link(resolved, filepath.Join(t.TempDir(), "alias")); e != nil {
					t.Fatal(e)
				}
			case "oversize":
				if e := os.Rename(live, resolved); e != nil {
					t.Fatal(e)
				}
				if e := os.WriteFile(resolved, make([]byte, (4<<20)+1), 0600); e != nil {
					t.Fatal(e)
				}
			case "python-pending", "python-complete":
				status := strings.TrimPrefix(variant, "python-")
				if e := os.WriteFile(live, encoded(object{"version": 2, "home": home, "id": rootID, "status": status, "members": []any{object{"id": rootID}}}), 0600); e != nil {
					t.Fatal(e)
				}
			}
			pending, e := pendingRuns(home)
			if variant == "complete" || variant == "python-complete" {
				if e != nil || len(pending) != 0 {
					t.Fatal(pending, e)
				}
			} else if variant == "python-pending" {
				if e != nil || len(pending) != 1 || pending[0] != name {
					t.Fatal(pending, e)
				}
			} else if e == nil {
				t.Fatal("unknown or unsafe record ignored", variant)
			}
		})
	}
}
