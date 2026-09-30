//go:build windows

package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

// 소유 테스트 실행파일의 좁은 하위 프로세스. vendor engine/auth/socket은 사용하지 않는다.
func init() {
	switch os.Getenv("CTXHOP_OWNED_JOB_FIXTURE") {
	case "pipe":
		os.Stdout.WriteString("fixture-ready\n")
		io.Copy(io.Discard, os.Stdin)
		os.Exit(0)
	case "child":
		exe, _ := os.Executable()
		child := exec.Command(exe)
		child.Env = []string{"CTXHOP_OWNED_JOB_FIXTURE=grandchild"}
		child.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		if e := child.Start(); e != nil {
			os.Exit(3)
		}
		os.Stdout.WriteString("descendant-ready\n")
		io.Copy(io.Discard, os.Stdin)
		os.Exit(0)
	case "grandchild":
		time.Sleep(5 * time.Minute)
		os.Exit(0)
	}
}
func TestNativeJobAndPreparedIdentity(t *testing.T) {
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	p, e := startProcess(exe, t.TempDir(), []string{"CTXHOP_OWNED_JOB_FIXTURE=pipe"})
	if e != nil {
		t.Fatal(e)
	}
	defer p.close()
	var nested int32
	proc("IsProcessInJob").Call(^uintptr(0), 0, uintptr(unsafe.Pointer(&nested)))
	t.Logf("parent Job membership=%t; child assigned to owned Job", nested != 0)
	line, e := streamLine(bufio.NewReader(p.Out))
	if e != nil || string(line) != "fixture-ready" {
		t.Fatal(string(line), e)
	}
	p.prepared = true
	if e = p.provePrepared(); e != nil {
		t.Fatal(e)
	}
	p.Created++
	assertCode(t, p.provePrepared(), "guard_binding")
	p.Created--
	if e = p.close(); e != nil {
		t.Fatal(e)
	}
	if !p.closed {
		t.Fatal("active0")
	}
}
func TestNativeJobAssignmentFailure(t *testing.T) {
	old := assignOwnedJob
	defer func() { assignOwnedJob = old }()
	var held syscall.Handle
	assignOwnedJob = func(job, h syscall.Handle) error {
		syscall.DuplicateHandle(syscall.Handle(^uintptr(0)), h, syscall.Handle(^uintptr(0)), &held, 0, false, syscall.DUPLICATE_SAME_ACCESS)
		return syscall.ERROR_ACCESS_DENIED
	}
	exe, _ := os.Executable()
	_, e := startProcess(exe, t.TempDir(), []string{"CTXHOP_OWNED_JOB_FIXTURE=pipe"})
	assertCode(t, e, "job_assignment")
	if held == 0 {
		t.Fatal("owned suspended PID not observed")
	}
	defer syscall.CloseHandle(held)
	var code uint32
	if e = syscall.GetExitCodeProcess(held, &code); e != nil || code == 259 {
		t.Fatal("owned suspended process survived assignment failure", code, e)
	}
}
func TestNativeJobDescendants(t *testing.T) {
	exe, _ := os.Executable()
	p, e := startProcess(exe, t.TempDir(), []string{"CTXHOP_OWNED_JOB_FIXTURE=child"})
	if e != nil {
		t.Fatal(e)
	}
	defer p.close()
	line, e := streamLine(bufio.NewReader(p.Out))
	if e != nil || string(line) != "descendant-ready" {
		t.Fatal(string(line), e)
	}
	n, e := p.active()
	if e != nil || n < 2 {
		t.Fatal("descendant not in owned Job", n, e)
	}
	if e = p.close(); e != nil {
		t.Fatal(e)
	}
	if !p.closed {
		t.Fatal("job active")
	}
}
func TestNativeImageHolding(t *testing.T) {
	dir := t.TempDir()
	image := filepath.Join(dir, "pinned-image.bin")
	os.WriteFile(image, []byte("pinned"), 0600)
	locks, e := lockImage(image)
	if e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(image, []byte("changed"), 0600); e == nil {
		t.Fatal("write bypassed held image")
	}
	if e = moveFile(image, filepath.Join(dir, "replacement.bin"), false); e == nil {
		t.Fatal("rename bypassed held image")
	}
	for _, f := range locks {
		f.Close()
	}
	if e = os.WriteFile(image, []byte("after-close"), 0600); e != nil {
		t.Fatal(e)
	}
}
func TestNativeGuardObservation(t *testing.T) {
	e := guard(nil)
	if e != nil && reason(e) != "engine_open" {
		t.Fatal(e)
	}
	if e == nil {
		t.Log("actual guard closed: no external writer observed")
	} else {
		t.Log("actual guard rejected external writer/unknown snapshot; no process terminated")
	}
}
func sqliteFixture(t *testing.T, dir string, wal bool, sql string) func() {
	t.Helper()
	system, e := systemDirectory()
	if e != nil {
		t.Fatal(e)
	}
	dll, e := syscall.LoadDLL(filepath.Join(system, "winsqlite3.dll"))
	if e != nil {
		t.Fatal(e)
	}
	open := dll.MustFindProc("sqlite3_open_v2")
	closeDB := dll.MustFindProc("sqlite3_close")
	execSQL := dll.MustFindProc("sqlite3_exec")
	var db uintptr
	b := append([]byte(filepath.Join(dir, "state_5.sqlite")), 0)
	r, _, _ := open.Call(uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(&db)), 6, 0)
	if r != 0 {
		t.Fatal("fixture open", r)
	}
	if wal {
		sql = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; " + sql
	}
	b = append([]byte(sql), 0)
	r, _, _ = execSQL.Call(db, uintptr(unsafe.Pointer(&b[0])), 0, 0, 0)
	if r != 0 {
		closeDB.Call(db)
		dll.Release()
		t.Fatal("fixture SQL", r)
	}
	return func() { closeDB.Call(db); dll.Release() }
}

const fixtureSQL = `CREATE TABLE threads(id TEXT PRIMARY KEY); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT NOT NULL,child_thread_id TEXT NOT NULL PRIMARY KEY,status TEXT NOT NULL);`

func liveFixtureSQL(t *testing.T) string {
	t.Helper()
	seal, e := liveSchema()
	if e != nil {
		t.Fatal(e)
	}
	var sql strings.Builder
	// The migrated schema retains sqlite_sequence after its earlier AUTOINCREMENT
	// table was replaced. Recreate that history in this new synthetic namespace.
	sql.WriteString("CREATE TABLE fixture_sequence(id INTEGER PRIMARY KEY AUTOINCREMENT); DROP TABLE fixture_sequence;\n")
	for _, kind := range []string{"table", "index", "trigger", "view"} {
		for _, raw := range array(seal["objects"]) {
			row := obj(raw)
			if row["type"] == kind && row["name"] != "sqlite_sequence" && row["sql"] != nil {
				sql.WriteString(text(row["sql"]))
				sql.WriteString(";\n")
			}
		}
	}
	for _, raw := range array(seal["migrations"]) {
		m := obj(raw)
		v, _ := integer(m["version"])
		fmt.Fprintf(&sql, "INSERT INTO _sqlx_migrations(version,description,success,checksum,execution_time) VALUES(%d,'owned synthetic schema',1,X'%s',0);\n", v, text(m["checksum"]))
	}
	return sql.String()
}
func liveFixtureThread(id string) string {
	return `INSERT INTO threads(id,rollout_path,created_at,updated_at,source,model_provider,cwd,title,sandbox_policy,approval_mode) VALUES('` + id + `','D:/Go/owned-rollout.jsonl',1,1,'cli','openai','D:/Go','fixture','read-only','untrusted');`
}

func TestNativeReadOnlyDB(t *testing.T) {
	t.Run("hidden_and_foreign", func(t *testing.T) {
		home := t.TempDir()
		close := sqliteFixture(t, home, false, liveFixtureSQL(t)+liveFixtureThread(rootID))
		close()
		v, e := checkDB(home, filepath.Join(home, "state_5.sqlite"), []member{{ID: rootID}}, false)
		if e != nil || !v.IDs[rootID] {
			t.Fatal(e, v)
		}
		close = sqliteFixture(t, home, false, `INSERT INTO thread_spawn_edges VALUES('`+rootID+`','`+otherID+`','open');`)
		close()
		_, e = checkDB(home, filepath.Join(home, "state_5.sqlite"), []member{{ID: rootID}}, false)
		assertCode(t, e, "foreign_link")
	})
	t.Run("WAL_and_SHM", func(t *testing.T) {
		source := t.TempDir()
		close := sqliteFixture(t, source, true, liveFixtureSQL(t)+liveFixtureThread(rootID))
		defer close()
		home := t.TempDir()
		for _, name := range []string{"state_5.sqlite", "state_5.sqlite-wal"} {
			b, e := os.ReadFile(filepath.Join(source, name))
			if e != nil {
				t.Fatal(e)
			}
			os.WriteFile(filepath.Join(home, name), b, 0600)
		}
		before, _ := dbHashes(filepath.Join(home, "state_5.sqlite"))
		v, e := checkDB(home, filepath.Join(home, "state_5.sqlite"), []member{{ID: rootID}}, false)
		if e != nil || !v.IDs[rootID] {
			t.Fatal(e)
		}
		after, _ := dbHashes(filepath.Join(home, "state_5.sqlite"))
		if string(encoded(before)) != string(encoded(after)) {
			t.Fatal("body/WAL changed")
		}
		if _, e = os.Stat(filepath.Join(home, "state_5.sqlite-shm")); !os.IsNotExist(e) {
			t.Fatal("original SHM namespace changed", e)
		}
		os.Remove(filepath.Join(home, "state_5.sqlite-wal"))
		missingBefore, _ := dbHashes(filepath.Join(home, "state_5.sqlite"))
		_, e = checkDB(home, filepath.Join(home, "state_5.sqlite"), []member{{ID: rootID}}, false)
		assertCode(t, e, "engine_db_unknown")
		missingAfter, _ := dbHashes(filepath.Join(home, "state_5.sqlite"))
		if string(encoded(missingBefore)) != string(encoded(missingAfter)) {
			t.Fatal("missing WAL gate wrote body/WAL")
		}
	})
	t.Run("missing", func(t *testing.T) {
		home := t.TempDir()
		_, e := checkDB(home, filepath.Join(home, "state_5.sqlite"), nil, false)
		assertCode(t, e, "engine_db_unknown")
		if _, e = checkDB(home, filepath.Join(home, "state_5.sqlite"), nil, true); e != nil {
			t.Fatal(e)
		}
	})
	t.Run("unknown", func(t *testing.T) {
		home := t.TempDir()
		close := sqliteFixture(t, home, false, `CREATE TABLE threads(wrong TEXT);`)
		close()
		_, e := checkDB(home, filepath.Join(home, "state_5.sqlite"), nil, false)
		assertCode(t, e, "engine_db_unknown")
	})
	t.Run("missing_edge_key", func(t *testing.T) {
		home := t.TempDir()
		close := sqliteFixture(t, home, false, `CREATE TABLE threads(id TEXT PRIMARY KEY); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT NOT NULL,status TEXT NOT NULL,unexpected TEXT);`)
		close()
		_, e := checkDB(home, filepath.Join(home, "state_5.sqlite"), nil, false)
		assertCode(t, e, "engine_db_unknown")
	})
	t.Run("other_state", func(t *testing.T) {
		home := t.TempDir()
		os.WriteFile(filepath.Join(home, "state_6.sqlite"), nil, 0600)
		_, e := checkDB(home, filepath.Join(home, "state_5.sqlite"), nil, true)
		assertCode(t, e, "engine_db_unknown")
	})
	t.Run("descriptor_outside", func(t *testing.T) {
		_, e := checkDB(t.TempDir(), filepath.Join(t.TempDir(), "state_5.sqlite"), nil, true)
		assertCode(t, e, "engine_db_unknown")
	})
}
func TestNativeReparse(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target")
	os.Mkdir(target, 0700)
	link := filepath.Join(dir, "link")
	if e := os.Symlink(target, link); e != nil {
		system, e := systemDirectory()
		if e != nil {
			t.Fatal(e)
		}
		if e = makeJunction(system, link, target); e != nil {
			t.Fatal(e)
		}
		t.Log("directory junction used; symlink privilege unavailable")
	}
	assertCode(t, noReparse(filepath.Join(link, "absent")), "reparse")
}

func TestLiveSchemaSealMutations(t *testing.T) {
	for _, sql := range []string{
		`ALTER TABLE threads ADD COLUMN unexpected TEXT;`,
		`DROP INDEX idx_threads_archived;`,
		`CREATE TRIGGER unknown_trigger AFTER DELETE ON threads BEGIN SELECT 1; END;`,
		`UPDATE _sqlx_migrations SET checksum=X'00' WHERE version=58;`,
		`UPDATE _sqlx_migrations SET success=0 WHERE version=58;`,
		`DELETE FROM _sqlx_migrations WHERE version=58;`,
	} {
		home := t.TempDir()
		close := sqliteFixture(t, home, false, liveFixtureSQL(t)+sql)
		close()
		before, e := dbHashes(filepath.Join(home, "state_5.sqlite"))
		if e != nil {
			t.Fatal(e)
		}
		_, e = checkDB(home, filepath.Join(home, "state_5.sqlite"), nil, false)
		assertCode(t, e, "engine_db_unknown")
		after, e := dbHashes(filepath.Join(home, "state_5.sqlite"))
		if e != nil || string(encoded(before)) != string(encoded(after)) {
			t.Fatal("schema rejection changed source", e)
		}
	}
}

func TestStateAttachmentAndDynamicToolReferencesBlock(t *testing.T) {
	for _, sql := range []string{
		`INSERT INTO thread_attachments VALUES('attachment','` + rootID + `','file','identity','{}',1);`,
		`INSERT INTO thread_dynamic_tools(thread_id,position,name,description,input_schema) VALUES('` + rootID + `',0,'tool','owned fixture','{}');`,
	} {
		home := t.TempDir()
		close := sqliteFixture(t, home, false, liveFixtureSQL(t)+liveFixtureThread(rootID)+sql)
		close()
		_, e := checkDB(home, filepath.Join(home, "state_5.sqlite"), []member{{ID: rootID}}, false)
		assertCode(t, e, "foreign_reference")
	}
}

func TestStateEdgesSurviveUnrelatedReferenceRows(t *testing.T) {
	home := t.TempDir()
	sql := liveFixtureSQL(t) + liveFixtureThread(rootID) + liveFixtureThread(childID) + liveFixtureThread(otherID) +
		`INSERT INTO thread_spawn_edges VALUES('` + rootID + `','` + childID + `','open');` +
		`INSERT INTO thread_dynamic_tools(thread_id,position,name,description,input_schema) VALUES('` + otherID + `',0,'unrelated','fixture','{}');`
	close := sqliteFixture(t, home, false, sql)
	close()
	v, e := checkDB(home, filepath.Join(home, "state_5.sqlite"), []member{{ID: rootID}, {ID: childID}}, false)
	if e != nil || len(v.Edges) != 1 || v.Edges[0]["parent_thread_id"] != rootID || v.Edges[0]["child_thread_id"] != childID {
		t.Fatal("edge rows lost behind unrelated references", e, v.Edges)
	}
	_, e = checkDB(home, filepath.Join(home, "state_5.sqlite"), []member{{ID: rootID}}, false)
	assertCode(t, e, "foreign_link")
}
func makeJunction(system, link, target string) error {
	cmd := exec.Command(filepath.Join(system, "cmd.exe"), "/d", "/c", "mklink", "/J", link, target)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if b, e := cmd.CombinedOutput(); e != nil {
		return fmt.Errorf("junction fixture: %w %s", e, b)
	}
	return nil
}
func TestEnginePinFailClosed(t *testing.T) {
	old := engineSHA256
	engineSHA256 = ""
	defer func() { engineSHA256 = old }()
	_, e := enginePath(options{Engine: filepath.Join(t.TempDir(), "engine.exe")})
	assertCode(t, e, "engine_untrusted")
	if versionAllowed("0.155.9") || !versionAllowed("0.156.0-alpha") || !versionAllowed("1.0.0") || versionAllowed("garbage") {
		t.Fatal("version")
	}
	if opRE.MatchString(strings.Repeat("A", 32)) {
		t.Fatal("run")
	}
}
