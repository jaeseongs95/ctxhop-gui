//go:build windows

package main

import (
	"errors"
	"fmt"
	"syscall"
	"unicode/utf8"
	"unsafe"
)

func sqliteTypedQuery(dll *syscall.DLL, db uintptr, sql string, params ...int64) (rows [][]any, retErr error) {
	b := append([]byte(sql), 0)
	var stmt uintptr
	r, _, _ := dll.MustFindProc("sqlite3_prepare_v2").Call(db, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)-1), uintptr(unsafe.Pointer(&stmt)), 0)
	if stmt == 0 {
		return nil, fmt.Errorf("schema SELECT prepare: %d", r)
	}
	defer func() {
		rc, _, _ := dll.MustFindProc("sqlite3_finalize").Call(stmt)
		if rc != 0 {
			retErr = errors.Join(retErr, fmt.Errorf("schema stmt drain: %d", rc))
		}
	}()
	if r != 0 {
		return nil, fmt.Errorf("schema SELECT prepare: %d", r)
	}
	for i, value := range params {
		r, _, _ := dll.MustFindProc("sqlite3_bind_int64").Call(stmt, uintptr(i+1), uintptr(value))
		if r != 0 {
			return nil, fmt.Errorf("schema SELECT bind: %d", r)
		}
	}
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
