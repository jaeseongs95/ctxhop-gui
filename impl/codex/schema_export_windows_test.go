//go:build windows && ctxhop_schema_export

package main

// A separate, opt-in test lane for the explicitly owned R43 synthetic fixture.
// The production CLI does not contain this flag or exporter.
import (
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"unicode/utf8"
	"unsafe"
)

const canonicalSyntheticSource = `D:\Go\codex-s4\run-helper2-v2-63fc48d2e59e48ef88ea7ef193662432\source-v2\state_5.sqlite`

var schemaExportOutput = flag.String("ctxhop-schema-export-output", "", "새 owned schema receipt 디렉터리")

func exportQuery(dll *syscall.DLL, db uintptr, sql string) (rows [][]any, retErr error) {
	b := append([]byte(sql), 0)
	var stmt uintptr
	r, _, _ := dll.MustFindProc("sqlite3_prepare_v2").Call(db, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)-1), uintptr(unsafe.Pointer(&stmt)), 0)
	if r != 0 {
		return nil, fmt.Errorf("schema SELECT prepare: %d", r)
	}
	defer func() {
		rc, _, _ := dll.MustFindProc("sqlite3_finalize").Call(stmt)
		if rc != 0 {
			retErr = errors.Join(retErr, fmt.Errorf("schema stmt drain: %d", rc))
		}
	}()
	var bytesRead int
	for {
		r, _, _ = dll.MustFindProc("sqlite3_step").Call(stmt)
		if r == 101 {
			return rows, nil
		}
		if r != 100 || len(rows) >= 10000 {
			return nil, fmt.Errorf("schema SELECT step/limit: %d", r)
		}
		n, _, _ := dll.MustFindProc("sqlite3_column_count").Call(stmt)
		if n > 16 {
			return nil, fmt.Errorf("schema column limit")
		}
		row := make([]any, n)
		for i := uintptr(0); i < n; i++ {
			kind, _, _ := dll.MustFindProc("sqlite3_column_type").Call(stmt, i)
			switch kind {
			case 5:
				row[i] = nil
			case 1:
				v, _, _ := dll.MustFindProc("sqlite3_column_int64").Call(stmt, i)
				row[i] = int64(v)
			case 3:
				ptr, _, _ := dll.MustFindProc("sqlite3_column_text").Call(stmt, i)
				length, _, _ := dll.MustFindProc("sqlite3_column_bytes").Call(stmt, i)
				if length > lineLimit || bytesRead+int(length) > 32<<20 || (ptr == 0 && length != 0) {
					return nil, fmt.Errorf("schema text size/pointer")
				}
				value := make([]byte, length)
				if length > 0 {
					proc("RtlMoveMemory").Call(uintptr(unsafe.Pointer(&value[0])), ptr, length)
				}
				if !utf8.Valid(value) {
					return nil, fmt.Errorf("schema text UTF-8")
				}
				bytesRead += int(length)
				row[i] = string(value)
			default:
				return nil, fmt.Errorf("unexpected schema cell type: %d", kind)
			}
		}
		rows = append(rows, row)
	}
}
func exportPrivateSchema(dll *syscall.DLL, path string) (result object, retErr error) {
	uri := url.URL{Scheme: "file", Path: "/" + filepath.ToSlash(path), RawQuery: "mode=ro"}
	b := append([]byte(uri.String()), 0)
	var db uintptr
	r, _, _ := dll.MustFindProc("sqlite3_open_v2").Call(uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(&db)), 0x41, 0)
	if db != 0 {
		defer func() {
			rc, _, _ := dll.MustFindProc("sqlite3_close").Call(db)
			if rc != 0 {
				retErr = errors.Join(retErr, fmt.Errorf("schema pool drain: %d", rc))
			}
		}()
	}
	if r != 0 {
		return nil, fmt.Errorf("private schema SQLite open: %d", r)
	}
	version, e := exportQuery(dll, db, "SELECT sqlite_version(),sqlite_source_id()")
	if e != nil {
		return nil, e
	}
	objects, e := exportQuery(dll, db, "SELECT type,name,tbl_name,rootpage,sql FROM sqlite_master ORDER BY type,name")
	if e != nil {
		return nil, e
	}
	tables := object{}
	migrationsFound := false
	for _, row := range objects {
		if row[0] != "table" {
			continue
		}
		name, ok := row[1].(string)
		if !ok {
			return nil, fmt.Errorf("schema object name")
		}
		if name == "_sqlx_migrations" {
			migrationsFound = true
		}
		// One quoted string argument; unknown table names cannot become SQL.
		rows, e := exportQuery(dll, db, "PRAGMA table_xinfo('"+strings.ReplaceAll(name, "'", "''")+"')")
		if e != nil {
			return nil, e
		}
		tables[name] = rows
	}
	if !migrationsFound {
		return nil, fmt.Errorf("synthetic source has no migration metadata")
	}
	migrations, e := exportQuery(dll, db, "SELECT version,success,hex(checksum) FROM _sqlx_migrations ORDER BY version")
	if e != nil {
		return nil, e
	}
	objectRows, migrationRows := []any{}, []any{}
	for _, row := range objects {
		objectRows = append(objectRows, object{"type": row[0], "name": row[1], "tableName": row[2], "rootPage": row[3], "sql": row[4]})
	}
	for _, row := range migrations {
		migrationRows = append(migrationRows, object{"version": row[0], "success": row[1], "checksum": row[2]})
	}
	return object{"sqliteVersionAndSourceId": version, "objects": objectRows, "tableXinfoColumns": []string{"cid", "name", "type", "notnull", "dflt_value", "pk", "hidden"}, "tableXinfo": tables, "migrations": migrationRows, "migrationCount": len(migrations)}, nil
}
func exportDLLVersion(path string) (string, error) {
	dll := syscall.NewLazyDLL("version.dll")
	u, _ := syscall.UTF16PtrFromString(path)
	size, _, e := dll.NewProc("GetFileVersionInfoSizeW").Call(uintptr(unsafe.Pointer(u)), 0)
	if size == 0 || size > lineLimit {
		return "", fmt.Errorf("DLL version size: %v", e)
	}
	b := make([]byte, size)
	r, _, e := dll.NewProc("GetFileVersionInfoW").Call(uintptr(unsafe.Pointer(u)), 0, size, uintptr(unsafe.Pointer(&b[0])))
	if r == 0 {
		return "", e
	}
	root, _ := syscall.UTF16PtrFromString(`\`)
	var value *byte
	var length uint32
	r, _, e = dll.NewProc("VerQueryValueW").Call(uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(root)), uintptr(unsafe.Pointer(&value)), uintptr(unsafe.Pointer(&length)))
	if r == 0 || value == nil || length < 52 {
		return "", fmt.Errorf("DLL fixed version: %v", e)
	}
	var fixed [13]uint32
	proc("RtlMoveMemory").Call(uintptr(unsafe.Pointer(&fixed[0])), uintptr(unsafe.Pointer(value)), 52)
	if fixed[0] != 0xfeef04bd {
		return "", fmt.Errorf("DLL fixed version signature")
	}
	return fmt.Sprintf("%d.%d.%d.%d", fixed[2]>>16, fixed[2]&0xffff, fixed[3]>>16, fixed[3]&0xffff), nil
}
func TestExportCanonicalSyntheticSchema(t *testing.T) {
	output := filepath.Clean(*schemaExportOutput)
	prefix := `D:\Go\codex-s4\`
	name := filepath.Base(output)
	helper2Output := strings.HasPrefix(name, "run-helper2-schema-") && opRE.MatchString(strings.TrimPrefix(name, "run-helper2-schema-")) && samePath(filepath.Dir(output), strings.TrimSuffix(prefix, `\`))
	helper3Output := name == "schema-export" && regexp.MustCompile(`^helper3-r45-fixture-[A-Za-z0-9_-]{1,80}$`).MatchString(filepath.Base(filepath.Dir(output))) && samePath(filepath.Dir(filepath.Dir(output)), strings.TrimSuffix(prefix, `\`))
	if !filepath.IsAbs(output) || len(output) <= len(prefix) || !strings.EqualFold(output[:len(prefix)], prefix) || (!helper2Output && !helper3Output) {
		t.Fatal("explicit fresh owned export output flag is required")
	}
	outputLocks := &testSnapshot{Files: map[string]snapshotEntry{}}
	defer func() {
		if e := outputLocks.Close(false); e != nil {
			t.Error(e)
		}
	}()
	if e := outputLocks.lockDirs(filepath.Dir(output)); e != nil {
		t.Fatal(e)
	}
	sid, sd, e := snapshotSecurity()
	if e != nil {
		t.Fatal(e)
	}
	sa := syscall.SecurityAttributes{Length: uint32(unsafe.Sizeof(syscall.SecurityAttributes{})), SecurityDescriptor: uintptr(unsafe.Pointer(sd))}
	u, _ := syscall.UTF16PtrFromString(output)
	r, _, createErr := proc("CreateDirectoryW").Call(uintptr(unsafe.Pointer(u)), uintptr(unsafe.Pointer(&sa)))
	proc("LocalFree").Call(uintptr(unsafe.Pointer(sd)))
	if r == 0 {
		t.Fatal(createErr)
	}
	if e := outputLocks.lockDirs(output); e != nil {
		t.Fatal(e)
	}
	if e := snapshotACL(output, sid); e != nil {
		t.Fatal(e)
	}
	// A busy production guard is recorded separately. It is never rewritten as
	// success or used as permission for a real engine/runtime.
	guardErr := guard(nil)
	guardResult := object{"status": "closed", "reasonCode": ""}
	if guardErr != nil {
		guardResult = object{"status": "busy-or-unknown", "reasonCode": reason(guardErr)}
	}
	s, e := acquireTestSnapshot(canonicalSyntheticSource, filepath.Join(output, "private"), limit, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	defer func() {
		if !s.Closed {
			if e := s.Close(true); e != nil {
				t.Error(e)
			}
		}
	}()
	system, e := systemDirectory()
	if e != nil {
		t.Fatal(e)
	}
	dllPath := filepath.Join(system, "winsqlite3.dll")
	locks, e := lockImage(dllPath)
	if e != nil {
		t.Fatal(e)
	}
	defer func() {
		for _, f := range locks {
			if e := f.Close(); e != nil {
				t.Error(e)
			}
		}
	}()
	dllHash, _, e := snapshotHash(locks[0], limit)
	if e != nil {
		t.Fatal(e)
	}
	fileVersion, e := exportDLLVersion(dllPath)
	if e != nil {
		t.Fatal(e)
	}
	dll, e := syscall.LoadDLL(dllPath)
	if e != nil {
		t.Fatal(e)
	}
	copyPath := filepath.Join(s.Private, "state_5.sqlite")
	before, e := dbHashes(copyPath)
	if e != nil {
		dll.Release()
		t.Fatal(e)
	}
	schema, queryErr := exportPrivateSchema(dll, copyPath)
	releaseErr := dll.Release()
	if e := errors.Join(queryErr, releaseErr); e != nil {
		t.Fatal(e)
	}
	if e := snapshotRegisterSidecars(s); e != nil {
		t.Fatal(e)
	}
	after, e := dbHashes(copyPath)
	if e != nil || before[copyPath] != after[copyPath] {
		t.Fatal("copy main query effect", e)
	}
	if before[copyPath+"-wal"] == "absent" {
		if after[copyPath+"-wal"] != "absent" && after[copyPath+"-wal"] != digest(nil) {
			t.Fatal("copy nonempty WAL creation")
		}
	} else if before[copyPath+"-wal"] != after[copyPath+"-wal"] {
		t.Fatal("copy existing WAL changed")
	}
	if e := s.Verify(limit); e != nil {
		t.Fatal(e)
	}
	sources, copies := object{}, object{}
	for name, entry := range s.Files {
		sources[name] = object{"identity": entry.Info, "sha256": entry.Hash, "size": int64(entry.Info.FileSizeHigh)<<32 | int64(entry.Info.FileSizeLow)}
	}
	for name, info := range s.Copies {
		copies[name] = object{"identity": info}
	}
	if e := s.Close(true); e != nil {
		t.Fatal(e)
	}
	finalGuardResult := object{"status": "closed", "reasonCode": ""}
	if e := guard(nil); e != nil {
		finalGuardResult = object{"status": "busy-or-unknown", "reasonCode": reason(e)}
	}
	finalDLLHash, _, e := snapshotHash(locks[0], limit)
	if e != nil || finalDLLHash != dllHash {
		t.Fatal("DLL image changed", e)
	}
	receipt := object{"schemaVersion": 1, "kind": "observed-synthetic-state-schema", "status": "observed", "source": canonicalSyntheticSource, "sourceFiles": sources, "copyIdentities": copies, "copyHashesBeforeQuery": before, "copyHashesAfterQuery": after, "sourceMainWALUnchanged": true, "sourceSHMCopied": false, "privateCopiesRemoved": true, "sourceReadShareHandlesDrained": true, "privateSQLiteReadersDrained": true, "privateOwnerSID": sid, "privateDACL": "protected-single-user", "productionGuardObservation": object{"before": guardResult, "after": finalGuardResult}, "absoluteWriterExclusion": false, "engineExecutions": 0, "sourceSQLiteOpens": 0, "sqlDirectWrites": 0, "threadRowsExported": 0, "canonicalEngineSchemaSeal": false, "dll": object{"path": dllPath, "sha256": dllHash, "fileVersion": fileVersion}}
	for key, value := range schema {
		receipt[key] = value
	}
	path := filepath.Join(output, "schema-export.json")
	if e := createFile(path, append(encoded(receipt), '\n')); e != nil {
		t.Fatal(e)
	}
	t.Logf("schema-only observed receipt: %s; migration count=%v; not a canonical Windows release schema seal", path, schema["migrationCount"])
}
