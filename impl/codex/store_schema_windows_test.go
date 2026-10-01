//go:build windows

package main

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// Reconstruction is only a unit fixture. The seal itself comes from the actual
// Rust factories; the separately tagged seed fixture reads their immutable bytes.
func storeSchemaFixtureSQL(t *testing.T, kind string) string {
	t.Helper()
	seal, e := storeSchemaSealV2()
	if e != nil {
		t.Fatal(e)
	}
	spec, e := storeSchemaForKindV2(seal, kind)
	if e != nil {
		t.Fatal(e)
	}
	objects := map[string]object{}
	var sql strings.Builder
	for _, raw := range array(spec["objects"]) {
		o := obj(raw)
		objects[text(o["name"])] = o
		if o["name"] == "sqlite_sequence" {
			sql.WriteString("CREATE TABLE fixture_sequence(id INTEGER PRIMARY KEY AUTOINCREMENT); DROP TABLE fixture_sequence;\n")
		}
	}
	for _, raw := range array(spec["tables"]) {
		table := obj(raw)
		o := objects[text(table["name"])]
		if o["name"] != "sqlite_sequence" {
			sql.WriteString(text(o["sql"]) + ";\n")
		}
	}
	// PRAGMA index_list enumerates newest declared indexes first. Reproduce the
	// observed sequence, including the table's original autoindexes.
	for _, raw := range array(spec["tables"]) {
		indexes := array(obj(raw)["indexes"])
		for i := len(indexes) - 1; i >= 0; i-- {
			o := objects[text(obj(indexes[i])["name"])]
			if o["sql"] != nil {
				sql.WriteString(text(o["sql"]) + ";\n")
			}
		}
	}
	for _, raw := range array(spec["objects"]) {
		o := obj(raw)
		if o["type"] == "trigger" || o["type"] == "view" {
			sql.WriteString(text(o["sql"]) + ";\n")
		}
	}
	for _, raw := range array(spec["migrations"]) {
		m := obj(raw)
		v, _ := integer(m["version"])
		fmt.Fprintf(&sql, "INSERT INTO _sqlx_migrations(version,description,success,checksum,execution_time) VALUES(%d,'unit fixture',1,X'%s',0);\n", v, text(m["checksumHex"]))
	}
	return sql.String()
}

func createStoreSchemaFixture(t *testing.T, home, kind, extra string) {
	t.Helper()
	build := t.TempDir()
	closeDB := sqliteFixture(t, build, false, storeSchemaFixtureSQL(t, kind)+extra)
	closeDB()
	for _, spec := range storeSpecs {
		if spec.Kind == kind {
			if e := moveFile(filepath.Join(build, "state_5.sqlite"), filepath.Join(home, spec.Filename), false); e != nil {
				t.Fatal(e)
			}
			return
		}
	}
	t.Fatal("unknown fixture kind")
}

func TestStoreEightActualSealAndPrivateReaders(t *testing.T) {
	for _, variant := range []string{"all-eight", "unrelated", "state", "logs", "goals", "memories", "memoriesV2", "queue", "threadHistory", "agentMessageBoard", "checksum", "success", "checksum-type", "board-migration"} {
		t.Run(variant, func(t *testing.T) {
			home := t.TempDir()
			targets := []storeTarget{}
			for _, spec := range storeSpecs {
				extra := ""
				if variant == spec.Kind {
					extra = "CREATE TABLE future_object(id TEXT);"
				}
				if spec.Kind == "logs" && variant == "unrelated" {
					extra = "INSERT INTO logs(ts,ts_nanos,level,target,thread_id) VALUES(1,1,'INFO','fixture','" + proofOutsideID + "');"
				}
				if spec.Kind == "goals" && variant == "checksum" {
					extra = "UPDATE _sqlx_migrations SET checksum=X'00' WHERE version=1;"
				}
				if spec.Kind == "memories" && variant == "success" {
					extra = "UPDATE _sqlx_migrations SET success=0 WHERE version=1;"
				}
				if spec.Kind == "queue" && variant == "checksum-type" {
					extra = "UPDATE _sqlx_migrations SET checksum=cast(checksum AS text) WHERE version=1;"
				}
				if spec.Kind == "agentMessageBoard" && variant == "board-migration" {
					extra = "CREATE TABLE _sqlx_migrations(version INTEGER);"
				}
				createStoreSchemaFixture(t, home, spec.Kind, extra)
				targets = append(targets, storeTarget{spec.Kind, filepath.Join(home, spec.Filename)})
			}
			s, e := acquireStoreSet(home, filepath.Join(t.TempDir(), "private"), targets, limit, nil, nil)
			if e != nil {
				t.Fatal(e)
			}
			defer s.Close(false)
			observation, proof, e := inspectPrivateStoreProof(context.Background(), s, relationTargets(t))
			if variant == "all-eight" || variant == "unrelated" {
				if e != nil || observation == nil || proof == nil {
					t.Fatal("sealed8 readonly proof", e)
				}
				for _, raw := range array(proof["members"]) {
					for _, relation := range array(obj(raw)["relations"]) {
						for _, value := range obj(obj(relation)["counts"]) {
							if n, ok := value.(int64); !ok || n != 0 {
								t.Fatal("unrelated/empty fixture counted as target", value)
							}
						}
					}
				}
			} else if e == nil || observation != nil || proof != nil {
				t.Fatal("future/changed schema returned complete proof", variant, e)
			}
			if s.ReadersOpen != 0 {
				t.Fatal("reader drain incomplete")
			}
			if e := s.Close(true); e != nil {
				t.Fatal("whole private cleanup", e)
			}
			if e := s.VerifyReleasedSources(nil); e != nil {
				t.Fatal("source vector changed", e)
			}
		})
	}
}
