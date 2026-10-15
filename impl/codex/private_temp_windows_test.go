//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func privateTempShortName(t *testing.T, path string) string {
	t.Helper()
	u, e := syscall.UTF16PtrFromString(path)
	if e != nil {
		t.Fatal(e)
	}
	buf := make([]uint16, 32768)
	n, e := syscall.GetShortPathName(u, &buf[0], uint32(len(buf)))
	if e != nil || n == 0 || n >= uint32(len(buf)) {
		t.Fatal("owned fixture short name", n, e)
	}
	short := syscall.UTF16ToString(buf[:n])
	if samePath(short, path) {
		t.Skip("fixture volume does not provide an 8.3 alias; short TEMP unverified")
	}
	return short
}

func TestNativeDBPrivateTempPaths(t *testing.T) {
	// Build Home before changing TEMP: only the private snapshot input varies.
	home := t.TempDir()
	state := filepath.Join(home, "state_5.sqlite")
	closeDB := sqliteFixture(t, home, false, liveFixtureSQL(t)+liveFixtureThread(rootID))
	closeDB()
	entry, e := snapshotOpen(home, true)
	if e != nil {
		t.Fatal("synthetic Home must already be canonical", e)
	}
	if e = entry.File.Close(); e != nil {
		t.Fatal(e)
	}
	before, e := dbHashes(state)
	if e != nil {
		t.Fatal(e)
	}
	temp := filepath.Join(t.TempDir(), "owned private snapshot temporary directory")
	if e = os.Mkdir(temp, 0700); e != nil {
		t.Fatal(e)
	}
	short := privateTempShortName(t, temp)
	sourceShort := privateTempShortName(t, home)
	link := filepath.Join(t.TempDir(), "junction")
	system, e := systemDirectory()
	if e != nil {
		t.Fatal(e)
	}
	if e = makeJunction(system, link, temp); e != nil {
		t.Fatal(e)
	}
	for _, tc := range []struct {
		name, temp, home string
		wantOK           bool
	}{
		{"long", temp, home, true},
		{"short", short, home, true},
		{"reparse", link, home, false},
		{"missing", filepath.Join(temp, "missing"), home, false},
		{"source-alias", temp, sourceShort, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("TMP", tc.temp)
			t.Setenv("TEMP", tc.temp)
			v, e := checkDB(tc.home, filepath.Join(tc.home, "state_5.sqlite"), []member{{ID: rootID}}, false)
			if tc.wantOK {
				if e != nil || !v.IDs[rootID] {
					t.Fatalf("canonical Home + %s TEMP must read synthetic DB: %v", tc.name, e)
				}
			} else {
				assertCode(t, e, "engine_db_unknown")
			}
			after, e := dbHashes(state)
			if e != nil || string(encoded(before)) != string(encoded(after)) {
				t.Fatal("source DB/WAL/SHM namespace or bytes changed", e)
			}
			entries, e := os.ReadDir(temp)
			if e != nil {
				t.Fatal(e)
			}
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), "ctxhop-acquisition-") {
					t.Fatal("private acquisition not cleaned", entry.Name())
				}
			}
			t.Logf("TEMP=%s; source unchanged; private cleanup complete", os.TempDir())
		})
	}
}
