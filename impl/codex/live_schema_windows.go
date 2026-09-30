//go:build windows

package main

import (
	"bytes"
	_ "embed"
	"strings"
	"syscall"
)

// Compiled from the previously observed synthetic schema and independently
// matched 58 CRLF migration checksums. Physical root-page numbers are storage
// allocation, not schema: type/name/table/SQL plus every xinfo cell are sealed.
// Runtime/provider equivalence and the distribution pins remain separate gates.
//
//go:embed live-schema-v159.json
var liveSchemaBytes []byte

func liveSchema() (object, error) {
	if digest(liveSchemaBytes) != "fa512da4bfce303783f4c7f10efca5d921194eed596ed08f2377ddea24f2ca4f" {
		return nil, fail("engine_db_unknown", "compiled live schema artifact 변경")
	}
	v, e := parseJSON(liveSchemaBytes)
	if e != nil {
		return nil, e
	}
	return obj(v), nil
}

func checkLiveSchema(dll *syscall.DLL, db uintptr) error {
	seal, e := liveSchema()
	if e != nil {
		return e
	}
	if normalEngineSHA256 != "" && normalEngineSHA256 != text(seal["normalEngineSha256"]) {
		return fail("engine_db_unknown", "normal engine과 live schema seal 대응 불명")
	}
	rows, e := sqliteTypedQuery(dll, db, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name")
	if e != nil {
		return fail("engine_db_unknown", "live schema objects 읽기 실패")
	}
	expected := array(seal["objects"])
	if len(rows) != len(expected) {
		return fail("engine_db_unknown", "live schema 객체 수 불일치")
	}
	for i, row := range rows {
		if len(row) != 4 {
			return fail("engine_db_unknown", "live schema 객체 구조 오류")
		}
		got := object{"type": row[0], "name": row[1], "tableName": row[2], "sql": row[3]}
		if !bytes.Equal(encoded(got), encoded(expected[i])) {
			return fail("engine_db_unknown", "live schema 객체/SQL 불일치")
		}
	}
	for table, expected := range obj(seal["tableXinfo"]) {
		rows, e := sqliteTypedQuery(dll, db, "PRAGMA table_xinfo('"+strings.ReplaceAll(table, "'", "''")+"')")
		if e != nil || !bytes.Equal(encoded(rows), encoded(expected)) {
			return fail("engine_db_unknown", "live schema 모든 열/type/xinfo 불일치")
		}
	}
	rows, e = sqliteTypedQuery(dll, db, "SELECT version,success,hex(checksum) FROM _sqlx_migrations ORDER BY version")
	expected = array(seal["migrations"])
	if e != nil || len(rows) != 58 || len(expected) != 58 {
		return fail("engine_db_unknown", "live schema migration 수/읽기 불일치")
	}
	for i, row := range rows {
		if len(row) != 3 {
			return fail("engine_db_unknown", "migration 구조 오류")
		}
		got := object{"version": row[0], "success": row[1], "checksum": row[2]}
		if !bytes.Equal(encoded(got), encoded(expected[i])) {
			return fail("engine_db_unknown", "migration 버전/성공/CRLF checksum 불일치")
		}
	}
	return nil
}
