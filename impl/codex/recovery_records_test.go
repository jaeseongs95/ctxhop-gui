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
				r := pythonRecoveryFixture(home, true)
				r["status"] = status
				if e := os.WriteFile(live, encoded(r), 0600); e != nil {
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

func pythonRecoveryFixture(home string, versioned bool) object {
	entry := object{"id": rootID, "path": filepath.Join(home, "sessions", "rollout-"+rootID+".jsonl"), "before": "absent", "after": strings.Repeat("a", 64), "beforeFile": nil, "afterFile": strings.Repeat("b", 64)}
	r := object{"status": "pending", "home": home, "id": rootID, "before": "absent", "createdDb": []any{}}
	if versioned {
		r["version"], r["members"], r["edges"] = 2, []any{entry}, []any{}
	} else {
		for key, value := range entry {
			r[key] = value
		}
		// Existing versionless journals can retain these unused compatibility fields.
		r["beforeData"], r["afterData"] = nil, nil
	}
	return r
}

func TestPythonRecoverySupportedMetadataAndUnsupportedBodies(t *testing.T) {
	variants := []string{"v2", "versionless", "update", "archived", "child-only", "missing-before", "missing-createdDb", "bad-createdDb", "missing-edges", "null-version", "wrong-version", "empty-members", "duplicate-member", "oversize-members", "bad-edge", "missing-edge-previous", "duplicate-edge", "foreign-path", "relative-path", "wrong-extension", "bad-beforeFile"}
	for _, field := range []string{"id", "path", "before", "after", "beforeFile", "afterFile"} {
		variants = append(variants, "missing-member-"+field)
	}
	for _, variant := range variants {
		t.Run(variant, func(t *testing.T) {
			home, run := t.TempDir(), strings.Repeat("e", 32)
			r := pythonRecoveryFixture(home, variant != "versionless")
			var entry object
			if variant == "versionless" {
				entry = r
			} else {
				entry = obj(array(r["members"])[0])
			}
			switch variant {
			case "update":
				r["before"], entry["before"], entry["beforeFile"] = strings.Repeat("c", 64), strings.Repeat("d", 64), strings.Repeat("e", 64)
			case "archived":
				entry["path"] = filepath.Join(home, "archived_sessions", "old.jsonl")
			case "child-only":
				// Python apply records only changed members; the existing parent/root
				// can therefore be outside the changed-member subset.
				entry["id"] = childID
				r["edges"] = []any{object{"parent_thread_id": rootID, "child_thread_id": childID, "status": "open", "previous": nil}}
			case "missing-before":
				delete(r, "before")
			case "missing-createdDb":
				delete(r, "createdDb")
			case "bad-createdDb":
				r["createdDb"] = []any{"foreign.sqlite"}
			case "missing-edges":
				delete(r, "edges")
			case "null-version":
				r["version"] = nil
			case "wrong-version":
				r["version"] = 3
			case "empty-members":
				r["members"] = []any{}
			case "duplicate-member":
				r["members"] = []any{entry, entry}
			case "oversize-members":
				r["members"] = make([]any, 2001)
			case "bad-edge", "missing-edge-previous", "duplicate-edge":
				edge := object{"parent_thread_id": childID, "child_thread_id": rootID, "status": "open", "previous": nil}
				if variant == "bad-edge" {
					edge["status"] = "future"
				}
				if variant == "missing-edge-previous" {
					delete(edge, "previous")
				}
				r["edges"] = []any{edge}
				if variant == "duplicate-edge" {
					r["edges"] = []any{edge, edge}
				}
			case "foreign-path":
				entry["path"] = filepath.Join(home, "foreign.jsonl")
			case "relative-path":
				entry["path"] = "sessions/file.jsonl"
			case "wrong-extension":
				entry["path"] = filepath.Join(home, "sessions", "file.jsonl.zst")
			case "bad-beforeFile":
				entry["beforeFile"] = strings.Repeat("c", 64)
			default:
				if strings.HasPrefix(variant, "missing-member-") {
					delete(entry, strings.TrimPrefix(variant, "missing-member-"))
				}
			}
			if err := createFile(filepath.Join(runPath(home, run), "journal.json"), encoded(r)); err != nil {
				t.Fatal(err)
			}
			valid := variant == "v2" || variant == "versionless" || variant == "update" || variant == "archived" || variant == "child-only"
			for index, row := range recoveryCLIRows(t, home, run) {
				if valid {
					if row.State != "pending" || row.Impl == nil || *row.Impl != "python" || !row.CanRollback || !row.CanResolve || row.CanFinalizeLocal || !row.BlocksImport || row.ReasonCode != nil {
						t.Fatal("supported legacy metadata rejected", row)
					}
				} else if row.State != "unreadable" || row.Impl != nil || row.CanRollback || row.CanFinalizeLocal || !row.CanResolve || !row.BlocksImport || row.ReasonCode == nil || *row.ReasonCode != "record_legacy_invalid" {
					t.Fatal("unsupported legacy body gained backend authority", row)
				}
				t.Logf("legacyContractRow[%s][%d]=%s", variant, index, encoded(row))
			}
		})
	}
}
