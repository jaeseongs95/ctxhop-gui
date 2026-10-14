//go:build windows

package main

import (
	"errors"
	"os"
	"path/filepath"
	"time"
)

func evidenceBudgetRoot(o options) string {
	parent := filepath.Dir(o.Home)
	if filepath.Base(o.Home) == "ref" && filepath.Base(parent) == o.Run && filepath.Base(filepath.Dir(parent)) == ".ctxhop-desktop-recovery" {
		return parent
	}
	return runPath(o.Home, o.Run)
}

// Count actual persisted bytes, including incomplete copies, before reserving
// any further copy. Separate files with identical contents count separately.
func preflightEvidenceCopies(root, run string, sizes ...int64) error {
	var total int64
	add := func(size int64) error {
		if size < 0 || size > limit-total {
			return fail("resourceLimit", "persisted evidence physical peak exceeds limit")
		}
		total += size
		return nil
	}
	seen := map[string]bool{}
	count := 0
	deadline := time.Now().Add(30 * time.Second)
	var walk func(string) error
	walk = func(path string) (retErr error) {
		if err := approvalExpired(deadline); err != nil {
			return err
		}
		count++
		if count > 100000 {
			return fail("resourceLimit", "evidence inventory count exceeds limit")
		}
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		entry, err := snapshotOpen(path, info.IsDir())
		if err != nil {
			return err
		}
		defer func() { retErr = errors.Join(retErr, entry.File.Close()) }()
		id := snapshotFileID(entry.Info)
		if seen[id] {
			return fail("recovery_evidence", "evidence physical alias rejected")
		}
		seen[id] = true
		if !info.IsDir() {
			return add(int64(uint64(entry.Info.FileSizeHigh)<<32 | uint64(entry.Info.FileSizeLow)))
		}
		children, err := snapshotDirectoryEntries(entry, 100001-count)
		if err != nil {
			return err
		}
		for _, child := range children {
			if err := walk(filepath.Join(path, child.Name())); err != nil {
				return err
			}
		}
		return nil
	}
	// Archive/stage and application rollouts have separate frozen budgets.
	for _, relative := range []string{"approval/members", "recovery/rollouts", "ref/.ctxhop-desktop-recovery/" + run + "/approval/members"} {
		if err := walk(filepath.Join(root, filepath.FromSlash(relative))); err != nil {
			return err
		}
	}
	for _, size := range sizes {
		if err := add(size); err != nil {
			return err
		}
	}
	return nil
}
