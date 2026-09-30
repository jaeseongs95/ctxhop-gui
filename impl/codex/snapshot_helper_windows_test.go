//go:build windows

package main

import (
	"path/filepath"
	"testing"
)

func snapshotAcquire(t *testing.T, source string) *dbAcquisition {
	t.Helper()
	s, e := acquireSnapshot(source, filepath.Join(t.TempDir(), "private"), limit, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		if !s.Closed {
			if e := s.Close(true); e != nil {
				t.Error(e)
			}
		}
	})
	return s
}
