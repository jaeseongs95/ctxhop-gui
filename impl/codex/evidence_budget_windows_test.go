//go:build windows

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func budgetSparseFile(t *testing.T, path string, size int64) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = f.Truncate(size); err != nil {
		t.Fatal(err)
	}
	if err = f.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestEvidencePhysicalBudgetCopiesAndPartialPeak(t *testing.T) {
	root, run := t.TempDir(), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	for _, name := range []string{"approval/members/0000.jsonl", "ref/.ctxhop-desktop-recovery/" + run + "/approval/members/0000.jsonl", "recovery/rollouts/000000.jsonl.zst"} {
		budgetSparseFile(t, filepath.Join(root, filepath.FromSlash(name)), limit/3)
	}
	// Three independent sparse zero-filled files have identical bytes. All three
	// count; only one byte of remaining headroom is available.
	if err := preflightEvidenceCopies(root, run, 1); err != nil {
		t.Fatal(err)
	}
	assertCode(t, preflightEvidenceCopies(root, run, 2), "resourceLimit")
	budgetSparseFile(t, filepath.Join(root, "recovery", "rollouts", "partial"), 2)
	assertCode(t, preflightEvidenceCopies(root, run), "resourceLimit")
}

func TestEvidenceBudgetRejectsRecoveryBeforeCopyWithReference(t *testing.T) {
	o, f, rollout, _ := recoveryRawFixture(t)
	root := runPath(o.Home, o.Run)
	var original int64
	for _, m := range f.Members {
		original += m.Size
	}
	budgetSparseFile(t, filepath.Join(root, "ref", ".ctxhop-desktop-recovery", o.Run, "approval", "members", "partial.jsonl"), limit-original-rollout.Source.Size+1)
	_, err := persistRecovery(o, f.Members, []recoveryRollout{rollout})
	assertCode(t, err, "resourceLimit")
	if _, err = os.Stat(filepath.Join(root, "recovery")); !os.IsNotExist(err) {
		t.Fatal("recovery copied before budget", err)
	}
}

func TestEvidenceBudgetReferenceApprovalPreflight(t *testing.T) {
	o, f, _ := approvalFixture(t)
	root := runPath(o.Home, o.Run)
	budgetSparseFile(t, filepath.Join(root, "recovery", "rollouts", "partial"), limit)
	ref := o
	ref.Home, ref.ApprovalEvidence = filepath.Join(root, "ref"), nil
	if evidenceBudgetRoot(ref) != root {
		t.Fatal("reference budget escaped original operation")
	}
	_, _, err := createApproval(ref, f)
	assertCode(t, err, "resourceLimit")
	if _, err = os.Stat(approvalPath(ref)); !os.IsNotExist(err) {
		t.Fatal("reference approval copied before budget", err)
	}
}

func TestEvidenceBudgetKeepsStageLimitSeparate(t *testing.T) {
	o, f, rollout, _ := recoveryRawFixture(t)
	root := runPath(o.Home, o.Run)
	budgetSparseFile(t, filepath.Join(root, "stage", "0000.jsonl"), limit)
	budgetSparseFile(t, filepath.Join(root, "ref", "stage", "0000.jsonl"), limit)
	if _, err := persistRecovery(o, f.Members, []recoveryRollout{rollout}); err != nil {
		t.Fatal("independent stage bytes narrowed evidence cap", err)
	}
}
