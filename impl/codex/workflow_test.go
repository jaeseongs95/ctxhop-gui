package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type mockHome struct {
	IDs      map[string]member
	Resumed  map[string]int
	Name     string
	Archived bool
}
type mockEngine struct {
	Homes       map[string]*mockHome
	Active      bool
	Deletes     int
	Events      []string
	Fail        string
	Attachments bool
	Family      *family
}

func installMock(t *testing.T, f *family) *mockEngine {
	t.Helper()
	oldPrepare, oldGuard, oldState, oldPreparedState := prepareEngine, checkGuard, readState, readPreparedState
	oldPin, oldLoader := engineSHA256, loaderContractID
	engineSHA256 = strings.Repeat("a", 64)
	loaderContractID = "fixture"
	m := &mockEngine{Homes: map[string]*mockHome{}, Family: f}
	prepareEngine = m.prepare
	checkGuard = func(p *process) error {
		m.Events = append(m.Events, "guard")
		if m.Active {
			return fail("mock_order", "guard while Job active")
		}
		return nil
	}
	readState = func(home, state string, ms []member, missing bool) (dbView, error) {
		if m.Active {
			return dbView{}, fail("mock_order", "DB while active")
		}
		m.Events = append(m.Events, "U-a-closed")
		h := m.home(home)
		hashes, e := dbHashes(state)
		v := dbView{IDs: map[string]bool{}, Count: len(h.IDs), Hashes: hashes}
		for id := range h.IDs {
			v.IDs[id] = true
		}
		if hashes[state] == "absent" && !missing {
			return v, fail("engine_db_unknown", "missing fixture DB")
		}
		return v, e
	}
	readPreparedState = func(home, state string, ms []member, missing bool) (dbView, error) {
		v, e := readState(home, state, ms, missing)
		var wal any
		if hash := v.Hashes[state+"-wal"]; hash != "absent" {
			wal = hash
		}
		v.Observation = mockObservation(state, v.Hashes[state], wal)
		return v, e
	}
	t.Cleanup(func() {
		prepareEngine = oldPrepare
		checkGuard = oldGuard
		readState = oldState
		readPreparedState = oldPreparedState
		engineSHA256 = oldPin
		loaderContractID = oldLoader
	})
	return m
}

// Protocol-only fixture descriptors, never native/provenance evidence.
func mockObservation(state, hash string, wal any) object {
	main := func(id string, sha any) object {
		return object{"identity": strings.Repeat(id, 24), "size": 4096, "sha256": sha}
	}
	var sw, pw any
	if wal != nil {
		sw, pw = main("5", wal), main("6", wal)
	}
	return object{"stateDb": state, "mainSha256": hash, "walSha256": wal, "acquisition": object{"schemaVersion": 1, "acquisitionId": strings.Repeat("a", 32), "rollbackJournalAbsent": true,
		"source":  object{"directoryIdentity": strings.Repeat("1", 24), "main": main("2", hash), "wal": sw, "shm": nil},
		"private": object{"directory": filepath.Join(os.TempDir(), "mock-private-acquisition"), "directoryIdentity": strings.Repeat("3", 24), "main": main("4", hash), "wal": pw},
	}}
}
func (m *mockEngine) home(home string) *mockHome {
	h := m.Homes[home]
	if h == nil {
		h = &mockHome{IDs: map[string]member{}, Resumed: map[string]int{}}
		m.Homes[home] = h
	}
	return h
}
func (m *mockEngine) prepare(o options, op string, ms []member) (*session, error) {
	if m.Active {
		return nil, fail("mock_order", "start while active")
	}
	m.Events = append(m.Events, "prepare-"+op)
	h := m.home(o.Home)
	s := &session{Projection: projection(o, op, ms, op == "plan" || op == "bootstrap"), Members: ms, Options: o, Operation: op}
	s.bind()
	s.Close = func() error { m.Events = append(m.Events, "Job-active-0"); m.Active = false; return nil }
	s.Notify = func(method string, p object) error {
		if method != "initialized" {
			return fail("mock_rpc", "notification")
		}
		return nil
	}
	s.Call = func(method string, p object) (object, error) {
		m.Events = append(m.Events, method)
		if m.Fail == method {
			return nil, fail("injected", "fixture phase failure")
		}
		switch method {
		case "ctxhop/complete":
			r := projection(o, op, ms, true)
			r["generation"] = num(2)
			r["acquisitionId"] = obj(obj(p["dbObservation"])["acquisition"])["acquisitionId"]
			return r, nil
		case "ctxhop/accept", "ctxhop/activate":
			r := object{}
			for k, v := range s.Binding {
				r[k] = v
			}
			if method == "ctxhop/accept" {
				r["accepted"] = true
			} else {
				r["activated"] = true
				m.Active = true
				state := filepath.Join(o.Home, "state_5.sqlite")
				if _, e := os.Stat(state); os.IsNotExist(e) {
					os.WriteFile(state, []byte("fixture state"), 0600)
				}
			}
			return r, nil
		case "initialize":
			return object{}, nil
		case "thread/read":
			id := text(p["threadId"])
			mem, exists := h.IDs[id]
			if !exists {
				for _, candidate := range m.Family.Members {
					if candidate.ID != id {
						continue
					}
					scan, e := scanHome(o.Home, m.Family.Members, false)
					if e != nil {
						return nil, e
					}
					if len(scan.Files[id]) > 0 {
						mem = candidate
						h.IDs[id] = mem
						exists = true
					}
				}
			}
			if !exists {
				return nil, &rpcError{Code: -32600}
			}
			return object{"thread": m.metadata(o, h, mem)}, nil
		case "thread/resume":
			id := text(p["threadId"])
			mem, ok := h.IDs[id]
			if !ok {
				return nil, &rpcError{Code: -32600}
			}
			first := p["sandbox"] == "read-only"
			if mem.Parent != nil && h.Resumed[*mem.Parent] == 0 {
				return nil, fail("mock_parent", "child before parent")
			}
			scan, e := scanHome(o.Home, m.Family.Members, false)
			if e != nil {
				return nil, e
			}
			if len(scan.Files[id]) != 1 {
				return nil, fail("mock_file", "file")
			}
			raw, _ := os.ReadFile(scan.Files[id][0])
			raw = append(raw, settings(id, o.Cwd, first)...)
			os.WriteFile(scan.Files[id][0], raw, 0600)
			h.Resumed[id]++
			kind := "workspaceWrite"
			if first {
				kind = "readOnly"
			}
			return object{"thread": m.metadata(o, h, mem), "approvalPolicy": "untrusted", "approvalsReviewer": "user", "cwd": o.Cwd, "sandbox": object{"type": kind}}, nil
		case "thread/name/set":
			h.Name = text(p["name"])
			return object{}, nil
		case "thread/turns/list":
			id := text(p["threadId"])
			mode := ""
			for _, member := range m.Family.Members {
				if member.ID == id {
					mode = text(obj(member.Data["thread"])["history_mode"])
				}
			}
			if mode == "legacy" && p["itemsView"] != "full" {
				return nil, fail("mock_history", "legacy must full")
			}
			return object{"data": []any{object{"id": "turn", "items": []any{object{"id": "message", "text": "안녕하세요"}}}}, "nextCursor": nil}, nil
		case "thread/items/list":
			return object{"data": []any{object{"id": "message", "text": "안녕하세요"}}, "nextCursor": nil}, nil
		case "thread/attachment/list":
			a := []any{}
			if m.Attachments {
				a = append(a, object{"id": "user-attachment"})
			}
			return object{"data": a, "nextCursor": nil}, nil
		case "thread/list":
			if p["useStateDbOnly"] != true {
				return nil, fail("mock_list", "thread/list must useStateDbOnly")
			}
			a := []any{}
			for _, member := range h.IDs {
				a = append(a, m.metadata(o, h, member))
			}
			return object{"data": a, "nextCursor": nil}, nil
		case "thread/archive":
			scan, e := scanHome(o.Home, m.Family.Members, true)
			if e != nil {
				return nil, e
			}
			for _, paths := range scan.Files {
				for _, path := range paths {
					dest := filepath.Join(o.Home, "archived_sessions", filepath.Base(path))
					os.MkdirAll(filepath.Dir(dest), 0700)
					if e = moveFile(path, dest, false); e != nil {
						return nil, e
					}
				}
			}
			h.Archived = true
			return object{}, nil
		case "thread/delete":
			m.Deletes++
			id := text(p["threadId"])
			for key, member := range h.IDs {
				if key != id && (member.Parent == nil || *member.Parent != id) {
					continue
				}
				scan, e := scanHome(o.Home, m.Family.Members, false)
				if e != nil {
					return nil, e
				}
				for _, path := range scan.Files[key] {
					os.Remove(path)
				}
				delete(h.IDs, key)
			}
			return object{}, nil
		default:
			return nil, fail("mock_rpc", "unknown method")
		}
	}
	return s, nil
}
func (m *mockEngine) metadata(o options, h *mockHome, member member) object {
	var parent any
	if member.Parent != nil {
		parent = *member.Parent
	}
	name := text(obj(member.Data["thread"])["title"])
	if member.ID == rootID && h.Name != "" {
		name = h.Name
	}
	return object{"id": member.ID, "parentThreadId": parent, "cwd": o.Cwd, "name": name, "title": name, "archived": h.Archived}
}
func importFixture(t *testing.T, mode string, archived bool) (options, *mockEngine) {
	f := fixtureFamily(mode)
	if archived {
		for _, m := range f.Members {
			obj(m.Data["thread"])["archived"] = num(1)
		}
		f.Archived = true
	}
	m := installMock(t, f)
	o := options{Home: t.TempDir(), Cwd: t.TempDir(), Archive: writeArchiveFixture(t, f, 2, nil), Run: strings.Repeat("b", 32)}
	r, e := plan(o)
	if e != nil || r["status"] != "new" {
		t.Fatalf("plan %v %v", r, e)
	}
	o.Token = text(r["token"])
	return o, m
}
func TestImportFixtures(t *testing.T) {
	for _, mode := range []string{"paginated", "legacy"} {
		for _, archived := range []bool{false, true} {
			t.Run(mode+map[bool]string{true: "-archived", false: "-active"}[archived], func(t *testing.T) {
				o, m := importFixture(t, mode, archived)
				r, e := importArchive(o)
				if e != nil {
					t.Fatalf("%v %v events=%v", r, e, m.Events)
				}
				if r["status"] != "imported" || m.Deletes != 0 || m.Active {
					t.Fatal(r)
				}
				j, e := loadJournal(o.Home, o.Run)
				if e != nil || j.Status != "complete" {
					t.Fatal(e, j)
				}
				if _, e = os.Stat(filepath.Join(runPath(o.Home, o.Run), "ref")); !os.IsNotExist(e) {
					t.Fatal("reference cleanup")
				}
			})
		}
	}
}

func TestPlanRoutingDoesNotFallbackOnSafetyFailure(t *testing.T) {
	for _, mode := range []string{"unsupported", "exists", "foreign_link", "unreadable_rollout", "reparse", "policy_error"} {
		t.Run(mode, func(t *testing.T) {
			o, m := importFixture(t, "legacy", false)
			f, e := readArchive(o.Archive)
			if e != nil {
				t.Fatal(e)
			}
			if e := support(f, o.Home); e != nil {
				t.Fatal(e)
			}
			switch mode {
			case "unsupported":
				obj(f.Members[0].Data["thread"])["source"] = `{"subagent":{}}`
				o.Archive = writeArchiveFixture(t, f, 2, nil)
			case "exists":
				if e := createFile(f.Members[0].Path, f.Members[0].Raw); e != nil {
					t.Fatal(e)
				}
			case "foreign_link":
				other := fixtureMember(otherID, nil, "legacy")
				other.Header["parent_thread_id"] = rootID
				if e := createFile(filepath.Join(o.Home, "sessions", "rollout-2023-11-14T22-13-20-"+otherID+".jsonl"), append(encoded(object{"type": "session_meta", "payload": other.Header}), '\n')); e != nil {
					t.Fatal(e)
				}
			case "unreadable_rollout":
				if e := createFile(f.Members[0].Path, []byte("invalid\n")); e != nil {
					t.Fatal(e)
				}
			case "reparse":
				system, e := systemDirectory()
				if e != nil {
					t.Fatal(e)
				}
				if e := makeJunction(system, filepath.Join(o.Home, "sessions"), t.TempDir()); e != nil {
					t.Fatal(e)
				}
			case "policy_error":
				old := prepareEngine
				defer func() { prepareEngine = old }()
				prepareEngine = func(options, string, []member) (*session, error) { return nil, fail("policy_error", "policy denied") }
			}
			m.Events = nil
			r, e := plan(o)
			if mode == "unsupported" || mode == "exists" {
				if e != nil || r["status"] != mode || len(m.Events) != 0 {
					t.Fatal(r, e, m.Events)
				}
				return
			}
			assertCode(t, e, mode)
			if r["status"] != "blocked" {
				t.Fatal("safety error permits fallback", r)
			}
		})
	}
}
func TestPendingAndExplicitRollback(t *testing.T) {
	o, m := importFixture(t, "paginated", false)
	m.Fail = "thread/resume"
	r, e := importArchive(o)
	assertCode(t, e, "injected")
	if r["status"] != "pending" || m.Deletes != 0 || m.Active {
		t.Fatal(r, m.Deletes)
	}
	m.Fail = ""
	r, e = rollback(o)
	if e != nil {
		t.Fatalf("rollback %v %v", r, e)
	}
	if r["status"] != "rolled_back" || m.Deletes != 1 {
		t.Fatal(r, m.Deletes)
	}
	r, e = rollback(o)
	if e != nil || r["status"] != "rolled_back" || m.Deletes != 1 {
		t.Fatal("idempotent", r, e)
	}
}
func TestRollbackRefusesUserAppendAndAttachment(t *testing.T) {
	for _, kind := range []string{"append", "attachment"} {
		t.Run(kind, func(t *testing.T) {
			o, m := importFixture(t, "legacy", false)
			m.Fail = "thread/turns/list"
			_, e := importArchive(o)
			assertCode(t, e, "injected")
			m.Fail = ""
			j, _ := loadJournal(o.Home, o.Run)
			if kind == "append" {
				path := j.Members[0].Path
				f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
				f.WriteString(`{"type":"event_msg","payload":{"type":"user_message"}}` + "\n")
				f.Close()
			} else {
				m.Attachments = true
			}
			_, e = rollback(o)
			if e == nil || m.Deletes != 0 {
				t.Fatal("unsafe deletion", e, m.Deletes)
			}
		})
	}
}
func TestRollbackRootAbsentDeletesOnlyRemainingLeaf(t *testing.T) {
	o, m := importFixture(t, "legacy", false)
	m.Fail = "thread/resume"
	_, e := importArchive(o)
	assertCode(t, e, "injected")
	m.Fail = ""
	j, _ := loadJournal(o.Home, o.Run)
	os.Remove(j.Members[0].Path)
	delete(m.home(o.Home).IDs, rootID)
	r, e := rollback(o)
	if e != nil || r["status"] != "rolled_back" || m.Deletes != 1 {
		t.Fatal(r, e, m.Deletes)
	}
}
func TestPrepareDBHiddenRowStopsPlacement(t *testing.T) {
	o, m := importFixture(t, "legacy", false)
	os.WriteFile(filepath.Join(o.Home, "state_5.sqlite"), []byte("fixture state"), 0600)
	m.home(o.Home).IDs[rootID] = m.Family.Members[0]
	r, e := importArchive(o)
	assertCode(t, e, "exists_in_engine")
	if r["status"] != "rolled_back" || m.Deletes != 0 {
		t.Fatal(r)
	}
	s, _ := scanHome(o.Home, m.Family.Members, false)
	if hasFiles(s) {
		t.Fatal("placed")
	}
}
func TestIncompleteSnapshotCannotActivate(t *testing.T) {
	s := &session{Projection: object{"inputComplete": false}}
	assertCode(t, s.activate(), "prestart_incomplete")
}
func TestPageCursorGuard(t *testing.T) {
	s := &session{Call: func(method string, p object) (object, error) {
		return object{"data": []any{"item"}, "nextCursor": "same"}, nil
	}}
	_, e := pages(s, "any", object{}, "data")
	assertCode(t, e, "rpc_page")
}
