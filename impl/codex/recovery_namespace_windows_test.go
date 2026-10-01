//go:build windows

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRecoveryListAbsentAndEmptyNamespace(t *testing.T) {
	home := t.TempDir()
	for _, exists := range []bool{false, true} {
		if exists {
			if err := os.Mkdir(filepath.Join(home, ".ctxhop-desktop-recovery"), 0700); err != nil {
				t.Fatal(err)
			}
		}
		rows, err := recoveryRecords(home)
		if err != nil || len(rows) != 0 {
			t.Fatalf("namespace exists=%v: rows=%v err=%v", exists, rows, err)
		}
	}
	if err := os.Mkdir(filepath.Join(home, ".ctxhop-desktop-recovery", "unknown-run"), 0700); err != nil {
		t.Fatal(err)
	}
	rows, err := recoveryRecords(home)
	if err != nil || len(rows) != 1 {
		t.Fatalf("unknown run: rows=%v err=%v", rows, err)
	}
	row := rows[0]
	if row.State != "unsafe" || !row.BlocksImport || row.RecordID != nil || row.CanRollback || row.CanResolve || row.CanFinalizeLocal {
		t.Fatalf("unknown run gained authority: %+v", row)
	}
}
