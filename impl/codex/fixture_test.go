package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const rootID = "11111111-1111-4111-8111-111111111111"
const childID = "22222222-2222-4222-8222-222222222222"
const otherID = "33333333-3333-4333-8333-333333333333"

func num(n int64) json.Number { return json.Number(fmt.Sprint(n)) }
func clone(v any) any {
	x, e := parseJSON(encoded(v))
	if e != nil {
		panic(e)
	}
	return x
}
func fixtureMember(id string, parent *string, mode string) member {
	row := object{}
	for k, c := range obj(columns["threads"]) {
		a := array(c)
		required, _ := integer(a[1])
		if required == 0 {
			row[k] = nil
		} else if text(a[0]) == "TEXT" {
			row[k] = ""
		} else {
			row[k] = num(0)
		}
	}
	cwd := `C:\origin`
	row["id"] = id
	row["created_at"] = num(1700000000)
	row["updated_at"] = num(1700000001)
	row["cwd"] = cwd
	row["title"] = "대화 제목"
	row["rollout_path"] = filepath.Join(cwd, "sessions", "rollout-2023-11-14T22-13-20-"+id+".jsonl")
	row["source"] = "cli"
	row["history_mode"] = mode
	row["archived"] = num(0)
	header := object{"id": id, "cwd": cwd, "cli_version": "0.158.0-alpha.2.1", "source": "cli"}
	if parent != nil {
		row["source"] = `{"subagent":{"thread_spawn":{"parent_thread_id":"` + *parent + `"}}}`
		header["parent_thread_id"] = *parent
		header["session_id"] = *parent
		header["source"] = mustObject([]byte(text(row["source"])))
		header["multi_agent_version"] = "v2"
	}
	rs := []object{{"type": "session_meta", "payload": header}, {"type": "event_msg", "payload": object{"type": "user_message", "message": "안녕하세요"}}}
	raw := []byte{}
	for _, r := range rs {
		raw = append(raw, append(encoded(r), '\n')...)
	}
	return member{ID: id, Parent: parent, Data: object{"thread": row, "history": object{"thread_turns": []any{}, "thread_items": []any{}, "thread_history_projection_state": []any{}, "thread_realtime_items": []any{}}, "dynamicTools": []any{}}, Raw: raw, Header: header, Records: rs, Size: int64(len(raw)), SHA256: digest(raw)}
}
func fixtureFamily(mode string) *family {
	p := rootID
	return &family{Members: []member{fixtureMember(rootID, nil, mode), fixtureMember(childID, &p, mode)}, Edges: []any{object{"parent_thread_id": rootID, "child_thread_id": childID, "status": "open"}}, EngineVersion: "0.158.0-alpha.2.1"}
}
func archiveBytes(f *family, format int, mutate func(object, map[string][]byte)) []byte {
	files := map[string][]byte{}
	if format == 1 {
		files["data.json"] = encoded(f.Members[0].Data)
		files["rollout.jsonl"] = f.Members[0].Raw
	} else {
		members := []any{}
		for i, m := range f.Members {
			members = append(members, m.Data)
			files[fmt.Sprintf("rollouts/%04d.jsonl", i)] = m.Raw
		}
		files["data.json"] = encoded(object{"members": members, "edges": f.Edges})
	}
	hashes := object{}
	for k, b := range files {
		hashes[k] = digest(b)
	}
	manifest := object{"format": format, "schema": trustedSchema, "engineVersion": f.EngineVersion, "hashes": hashes}
	if mutate != nil {
		mutate(manifest, files)
	}
	var b bytes.Buffer
	z := zip.NewWriter(&b)
	w, _ := z.Create("manifest.json")
	w.Write(encoded(manifest))
	for k, v := range files {
		w, _ = z.Create(k)
		w.Write(v)
	}
	z.Close()
	return b.Bytes()
}
func writeArchiveFixture(t *testing.T, f *family, format int, mutate func(object, map[string][]byte)) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "archive.zip")
	if e := os.WriteFile(p, archiveBytes(f, format, mutate), 0600); e != nil {
		t.Fatal(e)
	}
	return p
}
func assertCode(t *testing.T, e error, code string) {
	t.Helper()
	if e == nil || reason(e) != code {
		t.Fatalf("wanted %s, got %v (%s)", code, e, reason(e))
	}
}

func TestArchiveAndSupport(t *testing.T) {
	for _, format := range []int{1, 2} {
		t.Run(fmt.Sprint(format), func(t *testing.T) {
			f, e := readArchive(writeArchiveFixture(t, fixtureFamily("paginated"), format, nil))
			if e != nil {
				t.Fatal(e)
			}
			if e = support(f, t.TempDir()); e != nil {
				t.Fatal(e)
			}
			if len(f.Members) != format {
				t.Fatal("members")
			}
		})
	}
	for _, test := range []struct {
		name, code string
		mutate     func(*family)
	}{
		{"closed", "closed_edge", func(f *family) { obj(f.Edges[0])["status"] = "closed" }},
		{"grandchild", "grandchild", func(f *family) {
			p := childID
			m := fixtureMember(otherID, &p, "legacy")
			f.Members = append(f.Members, m)
			f.Edges = append(f.Edges, object{"parent_thread_id": childID, "child_thread_id": otherID, "status": "open"})
		}},
		{"subagent_root", "subagent_root", func(f *family) { obj(f.Members[0].Data["thread"])["source"] = `{"subagent":{}}` }},
		{"mixed_archived", "mixed_archived", func(f *family) { obj(f.Members[1].Data["thread"])["archived"] = num(1) }},
		{"title", "bad_title", func(f *family) { obj(f.Members[0].Data["thread"])["title"] = "bad\n" }},
		{"date", "created_at", func(f *family) { obj(f.Members[0].Data["thread"])["created_at"] = num(1) }},
		{"path", "bad_rollout_path", func(f *family) { obj(f.Members[0].Data["thread"])["rollout_path"] = "" }},
		{"suffix", "revert_rollout", func(f *family) {
			r := obj(f.Members[0].Data["thread"])
			r["rollout_path"] = strings.TrimSuffix(text(r["rollout_path"]), ".jsonl") + "_" + otherID + ".jsonl"
		}},
		{"roots", "extra_roots", func(f *family) { f.Members[0].Header["runtime_workspace_roots"] = []any{`C:\ORIGIN`} }},
		{"empty_own_roots", "extra_roots", func(f *family) {
			m := &f.Members[0]
			m.Records = append(m.Records, object{"type": "event_msg", "payload": object{"type": "thread_settings_applied", "thread_id": m.ID, "thread_settings": object{"cwd": `C:\origin`, "runtime_workspace_roots": []any{}}}})
		}},
		{"external_history", "external_history", func(f *family) { f.Members[0].Header["history_base"] = object{"thread_id": otherID} }},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := fixtureFamily("legacy")
			test.mutate(f)
			assertCode(t, support(f, t.TempDir()), test.code)
		})
	}
	for _, test := range []struct {
		name, code string
		mutate     func(object, map[string][]byte)
	}{
		{"hash", "archive_hash", func(m object, files map[string][]byte) { files["data.json"] = []byte(`{}`) }},
		{"extra_manifest", "archive_manifest", func(m object, files map[string][]byte) { m["unexpected"] = true }},
		{"schema", "archive_schema", func(m object, files map[string][]byte) { m["schema"] = object{} }},
		{"version", "archive_version", func(m object, files map[string][]byte) { m["engineVersion"] = "0.159.2" }},
		{"extra_zip", "archive_manifest", func(m object, files map[string][]byte) {
			files["../evil"] = []byte("evil")
			obj(m["hashes"])["../evil"] = digest(files["../evil"])
		}},
		{"header", "archive_rollout", func(m object, files map[string][]byte) {
			b := bytes.ReplaceAll(files["rollouts/0000.jsonl"], []byte(rootID), []byte(otherID))
			files["rollouts/0000.jsonl"] = b
			obj(m["hashes"])["rollouts/0000.jsonl"] = digest(b)
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, e := readArchive(writeArchiveFixture(t, fixtureFamily("legacy"), 2, test.mutate))
			assertCode(t, e, test.code)
		})
	}
	t.Run("duplicate_zip", func(t *testing.T) {
		var b bytes.Buffer
		z := zip.NewWriter(&b)
		for i := 0; i < 2; i++ {
			w, _ := z.Create("manifest.json")
			w.Write([]byte("{}"))
		}
		z.Close()
		p := filepath.Join(t.TempDir(), "dup.zip")
		os.WriteFile(p, b.Bytes(), 0600)
		_, e := readArchive(p)
		assertCode(t, e, "archive_zip")
	})
	t.Run("duplicate_json", func(t *testing.T) { _, e := parseJSON([]byte(`{"id":1,"id":2}`)); assertCode(t, e, "invalid_json") })
	t.Run("invalid_utf8", func(t *testing.T) { _, e := parseJSON([]byte{'"', 0xff, '"'}); assertCode(t, e, "invalid_json") })
	t.Run("truncated_zip", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "short.zip")
		b := archiveBytes(fixtureFamily("legacy"), 2, nil)
		os.WriteFile(p, b[:len(b)-20], 0600)
		_, e := readArchive(p)
		assertCode(t, e, "archive_zip")
	})
}
func TestV2Selection(t *testing.T) {
	m := fixtureMember(childID, ptr(rootID), "legacy")
	m.Records = append(m.Records, object{"type": "session_meta", "payload": object{"id": childID, "multi_agent_version": nil}}, object{"type": "session_meta", "payload": object{"id": otherID, "multi_agent_version": "v1"}})
	if multiAgentVersion(m) != "v2" {
		t.Fatal("latest null/foreign header")
	}
	for _, r := range m.Records {
		if text(r["type"]) == "session_meta" && text(obj(r["payload"])["id"]) == childID {
			delete(obj(r["payload"]), "multi_agent_version")
		}
	}
	m.Records = append(m.Records, object{"type": "compacted", "payload": object{"resume_metadata": object{"multi_agent_version": "v2"}}})
	if multiAgentVersion(m) != "v2" {
		t.Fatal("fallback")
	}
}
func ptr(s string) *string { return &s }
func settings(id, cwd string, first bool) []byte {
	s := object{"approval_policy": "untrusted", "approvals_reviewer": "user", "cwd": cwd, "runtime_workspace_roots": []any{cwd}, "permission_profile": object{"type": "managed", "network": "restricted", "file_system": object{"type": "restricted", "entries": []any{object{"access": "read", "path": object{"type": "special", "value": object{"kind": "root"}}}}}}}
	if !first {
		s["active_permission_profile"] = object{"id": ":workspace"}
	}
	return append(encoded(object{"type": "event_msg", "payload": object{"type": "thread_settings_applied", "thread_id": id, "thread_settings": s}}), '\n')
}
func TestScanAndPrefix(t *testing.T) {
	home := t.TempDir()
	f := fixtureFamily("legacy")
	support(f, home)
	m := f.Members[0]
	createFile(m.Path, m.Raw)
	s, e := scanHome(home, f.Members, false)
	if e != nil || !hasFiles(s) {
		t.Fatal(e)
	}
	b := append(append([]byte{}, m.Raw...), settings(m.ID, home, true)...)
	os.WriteFile(m.Path, b, 0600)
	if e = checkOwned(m, m.Path, home, true); e != nil {
		t.Fatal(e)
	}
	os.WriteFile(m.Path, append(b, []byte(`{"type":"event_msg","payload":{"type":"user_message"}}`+"\n")...), 0600)
	assertCode(t, checkOwned(m, m.Path, home, true), "user_append")
	os.WriteFile(m.Path, b, 0600)
	other := fixtureMember(otherID, nil, "legacy")
	other.Header["parent_thread_id"] = rootID
	other.Raw = append(encoded(object{"type": "session_meta", "payload": other.Header}), '\n')
	p := filepath.Join(home, "sessions", "rollout-2023-11-14T22-13-20-"+otherID+".jsonl")
	createFile(p, other.Raw)
	_, e = scanHome(home, f.Members, true)
	assertCode(t, e, "foreign_link")
	os.Remove(p)
	createFile(p+".zst", []byte("z"))
	_, e = scanHome(home, f.Members, true)
	assertCode(t, e, "compressed_rollouts")
}
func TestJournalAndMove(t *testing.T) {
	home := t.TempDir()
	run := runPath(home, strings.Repeat("a", 32))
	os.MkdirAll(run, 0700)
	f := fixtureFamily("legacy")
	support(f, home)
	j := &journal{Version: 3, Impl: "ctxhop-codex", Status: "pending", Phase: "created", Home: home, Cwd: home, ID: rootID, Members: f.Members, ArchiveSHA256: strings.Repeat("a", 64)}
	if e := saveJournal(run, j, true); e != nil {
		t.Fatal(e)
	}
	if e := saveJournal(run, j, true); e == nil {
		t.Fatal("overwrite")
	}
	if e := advance(run, j, "placed"); e == nil {
		t.Fatal("phase jump")
	}
	os.WriteFile(filepath.Join(run, "journal.tmp"), []byte("torn"), 0600)
	if e := advance(run, j, "staged"); e != nil {
		t.Fatal(e)
	}
	loaded, e := loadJournal(home, filepath.Base(run))
	if e != nil || loaded.Phase != "staged" {
		t.Fatal(e)
	}
	src, dst := filepath.Join(run, "src"), filepath.Join(run, "dst")
	os.WriteFile(src, []byte("new"), 0600)
	os.WriteFile(dst, []byte("old"), 0600)
	if e := moveFile(src, dst, false); e == nil {
		t.Fatal("replace")
	}
	b, _ := os.ReadFile(dst)
	if string(b) != "old" {
		t.Fatal("lost target")
	}
}

func projection(o options, op string, ms []member, complete bool) object {
	targets := []any{}
	for _, k := range []string{"state", "logs", "goals", "memories", "memoriesV2", "queue", "threadHistory"} {
		name := k + "_1.sqlite"
		if k == "state" {
			name = "state_5.sqlite"
		}
		targets = append(targets, object{"kind": k, "path": filepath.Join(o.Home, name)})
	}
	contexts := []any{object{"memberId": nil, "ownerId": nil, "phase": "startup", "cwd": o.Cwd, "rolloutSha256": nil, "settingsDigest": nil, "contextId": "startup", "sqliteHome": o.Home}}
	if complete {
		for _, m := range ms {
			phase := "firstResume"
			if op == "cold" {
				phase = "coldResume"
			}
			if op == "reference" {
				phase = "reference"
			}
			var sha, sd any = m.SHA256, strings.Repeat("a", 64)
			if op == "rollback" || op == "rollback-check" {
				if _, e := os.Stat(m.Path); os.IsNotExist(e) {
					phase = "rollbackAbsent"
					sha = nil
					sd = nil
				}
			}
			contexts = append(contexts, object{"memberId": m.ID, "ownerId": m.ID, "phase": phase, "cwd": o.Cwd, "rolloutSha256": sha, "settingsDigest": sd, "contextId": m.ID, "sqliteHome": o.Home})
		}
	}
	acquired := complete && op != "plan" && op != "bootstrap"
	var acquisitionID any
	if acquired {
		acquisitionID = strings.Repeat("a", 32)
	}
	return object{"contractVersion": num(1), "requestNonce": "nonce", "processId": num(123), "processNonce": "process", "snapshotId": "snapshot", "generation": num(1), "engineVersion": "0.159.2", "loaderContractId": loaderContractID, "inputComplete": complete, "home": o.Home, "normalSqliteHome": o.Home, "operationSqliteHome": o.Home, "stateDb": filepath.Join(o.Home, "state_5.sqlite"), "sqliteRedirect": false, "writeTargets": targets, "projectConfig": []any{}, "contexts": contexts, "authResolution": "resolved", "policyResolution": "resolved", "validity": object{"kind": "normal-loader-semantics", "revision": "stable-input", "expiresAt": nil}, "projectionDigest": strings.Repeat("a", 64), "acquisitionId": acquisitionID, "effects": object{"applicationWrites": num(0), "networkRequests": num(0), "sqliteShmMayChange": false, "privateSqliteSidecarsMayChange": acquired}}
}
func TestProjectionAndToken(t *testing.T) {
	old := loaderContractID
	loaderContractID = "fixture"
	defer func() { loaderContractID = old }()
	o := options{Home: t.TempDir(), Cwd: t.TempDir()}
	f := fixtureFamily("legacy")
	support(f, o.Home)
	p := projection(o, "import", f.Members, true)
	if e := validateProjection(p, "nonce", "import", o, f.Members, 123); e != nil {
		t.Fatal(e)
	}
	for _, mutation := range []struct {
		name string
		f    func(object)
	}{{"outside", func(p object) { p["normalSqliteHome"] = `C:\outside` }}, {"incomplete", func(p object) { p["inputComplete"] = false }}, {"effect", func(p object) { obj(p["effects"])["networkRequests"] = num(1) }}, {"PID", func(p object) { p["processId"] = num(124) }}, {"context", func(p object) { obj(array(p["contexts"])[1])["rolloutSha256"] = strings.Repeat("b", 64) }}, {"extra", func(p object) { p["surprise"] = true }}} {
		t.Run(mutation.name, func(t *testing.T) {
			q := obj(clone(p))
			mutation.f(q)
			if e := validateProjection(q, "nonce", "import", o, f.Members, 123); e == nil {
				t.Fatal("accepted")
			}
		})
	}
	a := tokenFor(o, f, p)
	q := obj(clone(p))
	q["processNonce"] = "different"
	q["snapshotId"] = "different"
	q["projectionDigest"] = strings.Repeat("b", 64)
	if tokenFor(o, f, q) != a {
		t.Fatal("process-bound token")
	}
	obj(q["validity"])["revision"] = "changed"
	if tokenFor(o, f, q) == a {
		t.Fatal("stale token")
	}
}

func TestAcquisitionWireRejectsUnknownAndUnboundProvenance(t *testing.T) {
	state := filepath.Join(t.TempDir(), "state_5.sqlite")
	o := mockObservation(state, strings.Repeat("a", 64), nil)
	if e := validateObservation(o, state); e != nil {
		t.Fatal(e)
	}
	mutations := []func(object){
		func(o object) { obj(o["acquisition"])["surprise"] = true },
		func(o object) { obj(o["acquisition"])["rollbackJournalAbsent"] = false },
		func(o object) { obj(obj(o["acquisition"])["source"])["directoryIdentity"] = "bad" },
		func(o object) {
			a := obj(o["acquisition"])
			obj(obj(a["private"])["main"])["identity"] = obj(obj(a["source"])["main"])["identity"]
		},
		func(o object) { obj(obj(obj(o["acquisition"])["private"])["main"])["sha256"] = strings.Repeat("b", 64) },
		func(o object) { obj(obj(obj(o["acquisition"])["source"])["main"])["size"] = num(1<<30 + 1) },
		func(o object) { o["walSha256"] = strings.Repeat("b", 64) },
		func(o object) {
			obj(obj(o["acquisition"])["private"])["wal"] = obj(obj(obj(o["acquisition"])["private"])["main"])
		},
	}
	for i, mutate := range mutations {
		q := obj(clone(o))
		mutate(q)
		if e := validateObservation(q, state); e == nil {
			t.Fatalf("provenance mutation %d accepted", i)
		}
	}
}
