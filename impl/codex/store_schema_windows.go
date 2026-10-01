//go:build windows

package main

import (
	"bytes"
	_ "embed"
	"strings"
	"syscall"
)

// Generated from frozen canonical factories in seed51, not reconstructed Go
// tables. Its provenance is not the protected binary's distribution pin.
//
//go:embed store-proof-v2-schema.json
var storeSchemaBytes []byte

func storeSchemaSealV2() (object, error) {
	if digest(storeSchemaBytes) != "6cad182f2f78614d5b239b56d5326c497e41e8a6e2b558b40d6ef5a3c9179067" {
		return nil, fail("engine_db_unknown", "actual8 schema seal 변경")
	}
	v, e := parseJSON(storeSchemaBytes)
	if e != nil {
		return nil, e
	}
	seal := obj(v)
	build := obj(obj(seal["provenance"])["build"])
	if normalEngineSHA256 != "" && normalEngineSHA256 != text(build["normalEngineSha256"]) {
		return nil, fail("engine_db_unknown", "normal engine과 actual8 schema profile 불일치")
	}
	return seal, nil
}

func storeSchemaForKindV2(seal object, kind string) (object, error) {
	stores := array(seal["stores"])
	if len(stores) != len(storeSpecs) {
		return nil, fail("engine_db_unknown", "actual8 schema seal 순서/개수 오류")
	}
	for i, spec := range storeSpecs {
		if obj(stores[i])["kind"] != spec.Kind {
			return nil, fail("engine_db_unknown", "actual8 schema seal kind 오류")
		}
		if kind == spec.Kind {
			return obj(stores[i]), nil
		}
	}
	return nil, fail("engine_db_unknown", "actual8 schema kind 불명")
}

func checkStoreSchemaV2(dll *syscall.DLL, db uintptr, kind string) error {
	seal, e := storeSchemaSealV2()
	if e != nil {
		return e
	}
	expected, e := storeSchemaForKindV2(seal, kind)
	if e != nil {
		return e
	}
	bad := func() error {
		return fail("engine_db_unknown", "actual8 schema 객체/열/FK/index/migration 불일치: "+kind)
	}
	query := func(sql string, columns ...string) ([]any, error) {
		rows, e := sqliteTypedQuery(dll, db, sql)
		if e != nil {
			return nil, bad()
		}
		result := []any{}
		for _, row := range rows {
			if len(row) != len(columns) {
				return nil, bad()
			}
			m := object{}
			for i, name := range columns {
				m[name] = row[i]
			}
			result = append(result, m)
		}
		return result, nil
	}
	quote := func(name string) string { return "'" + strings.ReplaceAll(name, "'", "''") + "'" }
	objects, e := query("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name", "type", "name", "table", "sql")
	if e != nil {
		return e
	}
	tables := []any{}
	for _, raw := range array(expected["tables"]) {
		table := obj(raw)
		name := text(table["name"])
		xinfo, e := query("PRAGMA table_xinfo("+quote(name)+")", "cid", "name", "type", "notnull", "dflt_value", "pk", "hidden")
		if e != nil {
			return e
		}
		foreignKeys, e := query("PRAGMA foreign_key_list("+quote(name)+")", "id", "seq", "table", "from", "to", "on_update", "on_delete", "match")
		if e != nil {
			return e
		}
		list, e := query("PRAGMA index_list("+quote(name)+")", "seq", "name", "unique", "origin", "partial")
		if e != nil {
			return e
		}
		indexes := []any{}
		for _, raw := range list {
			entry := obj(raw)
			index := text(entry["name"])
			if index == "" {
				return bad()
			}
			xinfo, e := query("PRAGMA index_xinfo("+quote(index)+")", "seqno", "cid", "name", "desc", "coll", "key")
			if e != nil {
				return e
			}
			indexes = append(indexes, object{"name": index, "listEntry": entry, "xinfo": xinfo})
		}
		tables = append(tables, object{"name": name, "xinfo": xinfo, "foreignKeys": foreignKeys, "indexes": indexes})
	}
	var migrations any
	if expected["migrations"] != nil {
		migrations, e = query("SELECT version,success,CASE WHEN typeof(checksum)='blob' THEN lower(hex(checksum)) ELSE NULL END FROM _sqlx_migrations ORDER BY version", "version", "success", "checksumHex")
		if e != nil {
			return e
		}
	}
	actual := object{"kind": kind, "objects": objects, "tables": tables, "migrations": migrations}
	a, e := storeCanonicalJSON(actual)
	if e != nil {
		return e
	}
	b, e := storeCanonicalJSON(expected)
	if e != nil || !bytes.Equal(a, b) {
		return bad()
	}
	return nil
}
