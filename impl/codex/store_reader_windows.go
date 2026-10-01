//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// This callable source API remains behind the schema gate. It is not wired to
// production complete/admission. Key facts still need canonical state metadata,
// strict file uncertainty and operation policy before they can authorize anything.
func inspectPrivateStoreKeys(ctx context.Context, s *storeAcquisition, targets *storeProofKeys) (facts []storeKeyEvidence, retErr error) {
	if ctx == nil || s == nil || targets == nil || !s.Finalized || s.Draining || s.Closed || s.ReadersOpen != 0 {
		return nil, fail("engine_db_unknown", "finalized aggregate store reader 결속 누락")
	}
	if e := s.Verify(); e != nil {
		return nil, e
	}
	// Check seal availability for every present store before the first SQLite open.
	for _, slot := range s.Stores {
		if slot.Present && slot.Kind != "state" {
			return nil, fail("engine_db_unknown", "actual auxiliary schema seal 미확보: "+slot.Kind)
		}
	}
	dir, e := systemDirectory()
	if e != nil {
		return nil, e
	}
	dll, e := syscall.LoadDLL(filepath.Join(dir, "winsqlite3.dll"))
	if e != nil {
		return nil, e
	}
	defer func() { retErr = errors.Join(retErr, dll.Release()) }()
	for _, name := range []string{"sqlite3_open_v2", "sqlite3_close", "sqlite3_interrupt", "sqlite3_db_readonly", "sqlite3_busy_timeout", "sqlite3_prepare_v2", "sqlite3_step", "sqlite3_finalize", "sqlite3_bind_int64", "sqlite3_column_type", "sqlite3_column_count", "sqlite3_column_int64", "sqlite3_column_text", "sqlite3_column_bytes"} {
		if _, e := dll.FindProc(name); e != nil {
			return nil, e
		}
	}
	defer func() {
		retErr = errors.Join(retErr, s.Verify())
		if retErr != nil {
			facts = nil
		}
	}()
	for _, slot := range s.Stores {
		if e := ctx.Err(); e != nil {
			return nil, e
		}
		if !slot.Present {
			facts = append(facts, storeKeyEvidence{Kind: slot.Kind})
			continue
		}
		proof, e := readFinalizedStoreKeys(ctx, dll, slot, targets)
		if e != nil {
			return nil, e
		}
		facts = append(facts, proof)
	}
	return facts, nil
}

func readFinalizedStoreKeys(parent context.Context, dll *syscall.DLL, slot storeSlot, targets *storeProofKeys) (proof storeKeyEvidence, retErr error) {
	if parent == nil || dll == nil || targets == nil || slot.Data == nil || !slot.Present || !slot.Data.privateCopyReady() || slot.Data.Aggregate == nil || slot.Data.Aggregate.ReadersOpen != 0 || slot.Kind != "state" {
		return proof, fail("engine_db_unknown", "private store reader/schema gate 결속 오류")
	}
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()
	path := filepath.Join(slot.Data.Private, filepath.Base(slot.Data.Source))
	uri := url.URL{Scheme: "file", Path: "/" + filepath.ToSlash(path), RawQuery: "mode=ro"}
	name := append([]byte(uri.String()), 0)
	var db uintptr
	r, _, _ := dll.MustFindProc("sqlite3_open_v2").Call(uintptr(unsafe.Pointer(&name[0])), uintptr(unsafe.Pointer(&db)), 0x41, 0)
	if db == 0 {
		return proof, fail("engine_db_unknown", "private store readonly 열기 실패")
	}
	slot.Data.Aggregate.ReadersOpen++
	// Join the interrupt goroutine before close: it must never touch a recycled handle.
	stop, done := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		select {
		case <-ctx.Done():
			// sqlite3_interrupt while idle does not cancel a later statement. Keep
			// interrupting until drain, including cancellation between schema queries.
			ticker := time.NewTicker(time.Millisecond)
			defer ticker.Stop()
			for {
				dll.MustFindProc("sqlite3_interrupt").Call(db)
				select {
				case <-stop:
					return
				case <-ticker.C:
				}
			}
		case <-stop:
		}
	}()
	defer func() {
		close(stop)
		<-done
		r, _, _ := dll.MustFindProc("sqlite3_close").Call(db)
		if r != 0 {
			retErr = errors.Join(retErr, fail("engine_db_unknown", "store reader close 실패"))
		} else {
			slot.Data.Aggregate.ReadersOpen--
		}
		retErr = errors.Join(retErr, ctx.Err())
		if retErr != nil {
			proof = storeKeyEvidence{}
		}
	}()
	if r != 0 {
		return proof, fail("engine_db_unknown", "private store readonly 열기 실패")
	}
	main := append([]byte("main"), 0)
	r, _, _ = dll.MustFindProc("sqlite3_db_readonly").Call(db, uintptr(unsafe.Pointer(&main[0])))
	if r != 1 {
		return proof, fail("engine_db_unknown", "private store readonly 확인 실패")
	}
	r, _, _ = dll.MustFindProc("sqlite3_busy_timeout").Call(db, 100)
	if r != 0 {
		return proof, fail("engine_db_unknown", "store busy timeout 설정 실패")
	}
	if _, e := sqliteTypedQuery(dll, db, "PRAGMA query_only=1"); e != nil {
		return proof, e
	}
	rows, e := sqliteTypedQuery(dll, db, "PRAGMA query_only")
	if e != nil || len(rows) != 1 || len(rows[0]) != 1 || rows[0][0] != int64(1) {
		return proof, fail("engine_db_unknown", "store query_only 확인 실패")
	}
	if _, e := sqliteTypedQuery(dll, db, "BEGIN"); e != nil {
		return proof, e
	}
	rows, e = sqliteTypedQuery(dll, db, "PRAGMA quick_check")
	if e != nil || len(rows) != 1 || len(rows[0]) != 1 || rows[0][0] != "ok" {
		return proof, fail("engine_db_unknown", "store integrity 불명")
	}
	if e := checkLiveSchema(dll, db); e != nil {
		return proof, e
	}
	remaining, buffered := storeKeyRowLimit, 0
	scan := func(table string, cols []storeKeyColumn) ([][]any, error) {
		if e := ctx.Err(); e != nil {
			return nil, e
		}
		// Only the fixed source reader supplies these identifiers; validate even that boundary.
		validIdentifier := func(s string) bool {
			if s == "" {
				return false
			}
			for _, c := range s {
				if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
					return false
				}
			}
			return true
		}
		if !validIdentifier(table) || len(cols) == 0 || len(cols) > 5 {
			return nil, fail("engine_db_unknown", "store key SELECT identifier 오류")
		}
		projection := []string{}
		for _, col := range cols {
			if !validIdentifier(col.Name) {
				return nil, fail("engine_db_unknown", "store key column 오류")
			}
			kind, value := "text", fmt.Sprintf("substr(%s,1,%d)", col.Name, storeColumnTextLimit(col.Name)+1)
			if col.Integer {
				kind, value = "integer", col.Name
			}
			projection = append(projection, fmt.Sprintf("CASE WHEN typeof(%s)='%s' THEN %s ELSE NULL END,typeof(%s),length(cast(%s AS blob))", col.Name, kind, value, col.Name, col.Name))
		}
		rows, e := sqliteTypedQuery(dll, db, "SELECT "+strings.Join(projection, ",")+" FROM "+table+" LIMIT ?", int64(remaining+1))
		if e != nil {
			return nil, e
		}
		if len(rows) > remaining {
			return nil, fail("engine_db_unknown", "store key row limit")
		}
		remaining -= len(rows)
		result := make([][]any, 0, len(rows))
		for _, row := range rows {
			if len(row) != len(cols)*3 {
				return nil, fail("engine_db_unknown", "store key row shape")
			}
			values := make([]any, len(cols))
			buffered += len(values) * 128
			for i, col := range cols {
				value, typ, size := row[i*3], row[i*3+1], row[i*3+2]
				if typ == "null" && col.Nullable && value == nil {
					continue
				}
				if col.Integer {
					if _, ok := value.(int64); !ok || typ != "integer" {
						return nil, fail("engine_db_unknown", "store key integer type")
					}
				} else {
					n, ok := size.(int64)
					if !ok || n < 0 || n > int64(storeColumnTextLimit(col.Name)) || typ != "text" {
						return nil, fail("engine_db_unknown", "store key text type/bytes")
					}
					str, ok := value.(string)
					if !ok || !validStoreKeyText(str, storeColumnTextLimit(col.Name)) || int64(len(str)) != n {
						return nil, fail("engine_db_unknown", "store key bounded UTF8 text")
					}
					buffered += len(str)
				}
				values[i] = value
			}
			if buffered > storeKeyBufferLimit {
				return nil, fail("engine_db_unknown", "store key buffer limit")
			}
			result = append(result, values)
		}
		return result, ctx.Err()
	}
	proof, e = readStoreKeyRelations(slot.Kind, targets, scan)
	if e != nil {
		return proof, e
	}
	if _, e := sqliteTypedQuery(dll, db, "COMMIT"); e != nil {
		return proof, e
	}
	return proof, nil
}
