//go:build windows && ctxhop_backend_sequence

package main

import (
	"bytes"
	"context"
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

// Test-only cross-backend lane. No flag or executable launch enters the CLI.
const historicalBackendTestSHA = "3494e9fe61a5756232f97066dfcfaa698dc1c0c78e2e72548bb59c310c5f19c0"
const historicalBackendArtifactSHA = "88a56530236aa95ea879ce908a7ae72c23922b1ce3374855ea0dcf3c86c4c2ec"
const backendSelector = "prestart_context::backend_tests::read_private_acquisition_from_fixture_manifest"

var backendMode = flag.String("ctxhop-backend-case", "", "explicit owned backend sequence case")
var backendCaseID = flag.String("ctxhop-backend-case-id", "", "fresh 32 lowercase hex case ID")

func backendDirectory(path string, sd *byte) error {
	u, e := syscall.UTF16PtrFromString(path)
	if e != nil {
		return e
	}
	sa := syscall.SecurityAttributes{Length: uint32(unsafe.Sizeof(syscall.SecurityAttributes{})), SecurityDescriptor: uintptr(unsafe.Pointer(sd))}
	r, _, e := proc("CreateDirectoryW").Call(uintptr(unsafe.Pointer(u)), uintptr(unsafe.Pointer(&sa)))
	if r == 0 {
		return e
	}
	return nil
}

func TestBackendSequence(t *testing.T) {
	if *backendMode == "" {
		t.Skip("requires explicit new owned case; no backend execution")
	}
	allowed := map[string]bool{"checkpoint": true, "empty-wal": true, "wal-only": true, "stale-shm": true, "decoder-error": true, "missing-private-copy": true, "nonempty-new-wal": true, "unknown-entry": true}
	if !allowed[*backendMode] || !opRE.MatchString(*backendCaseID) {
		t.Fatal("invalid explicit fixture selector/case ID")
	}
	metadata, e := loadFixtureMetadata()
	if e != nil {
		t.Fatal(e)
	}
	backendTestExe, e := fixtureSettingPath(metadata, "backendRustExecutable", false)
	if e != nil {
		t.Fatal(e)
	}
	backendTestSHA, backendArtifactSHA := text(metadata["backendRustExecutableSha256"]), text(metadata["backendRustArtifactSha256"])
	if !hashRE.MatchString(backendTestSHA) || !hashRE.MatchString(backendArtifactSHA) {
		t.Fatal("caller fixture image/artifact pins")
	}
	exeLocks, e := lockImage(backendTestExe)
	if e != nil {
		t.Fatal(e)
	}
	defer func() {
		for _, file := range exeLocks {
			if e := file.Close(); e != nil {
				t.Error(e)
			}
		}
	}()
	exeHash, _, e := snapshotHash(exeLocks[0], limit)
	if e != nil || exeHash != backendTestSHA {
		t.Fatal("fixed Rust test executable pin mismatch", e)
	}
	artifact, e := fixturePinnedFile(metadata, "backendRustArtifact", "backendRustArtifactSha256", lineLimit)
	if e != nil {
		t.Fatal("fixed Rust source artifact pin mismatch", e)
	}
	artifactValue, e := parseJSON(artifact)
	artifactRecord := obj(artifactValue)
	if e != nil || artifactRecord["sourceCommit"] != metadata["backendRustSourceCommit"] || !fixtureCommitRE.MatchString(text(metadata["backendRustSourceCommit"])) || !strings.EqualFold(text(artifactRecord["executableSha256"]), backendTestSHA) || artifactRecord["selector"] != backendSelector {
		t.Fatal("fixture artifact source/image/selector binding", e)
	}
	base, e := fixtureSettingPath(metadata, "backendNamespaceParent", true)
	if e != nil {
		t.Fatal(e)
	}
	// Go alone creates the common parent and cases; the runner only reads them.
	namespace := &dbAcquisition{Files: map[string]snapshotEntry{}}
	if e := namespace.lockDirs(filepath.Dir(base)); e != nil {
		t.Fatal(e)
	}
	defer func() {
		if e := namespace.Close(false); e != nil {
			t.Error(e)
		}
	}()
	sid, sd, e := snapshotSecurity()
	if e != nil {
		t.Fatal(e)
	}
	defer proc("LocalFree").Call(uintptr(unsafe.Pointer(sd)))
	if e := snapshotAbsent(base); e == nil {
		if e := backendDirectory(base, sd); e != nil {
			t.Fatal("new backend parent creation failed", e)
		}
	}
	if e := namespace.lockDirs(base); e != nil {
		t.Fatal(e)
	}
	root := filepath.Join(base, *backendCaseID)
	if e := backendDirectory(root, sd); e != nil {
		t.Fatal("fresh case CREATE_NEW failed", e)
	}
	if e := namespace.lockDirs(root); e != nil {
		t.Fatal(e)
	}
	if e := snapshotACL(root, sid); e != nil {
		t.Fatal(e)
	}
	seed, sourceHome := filepath.Join(root, "seed"), filepath.Join(root, "source")
	for _, dir := range []string{seed, sourceHome} {
		if e := backendDirectory(dir, sd); e != nil {
			t.Fatal(e)
		}
		if e := namespace.lockDirs(dir); e != nil {
			t.Fatal(e)
		}
	}
	sql := liveFixtureSQL(t) + liveFixtureThread(rootID)
	if *backendMode == "decoder-error" {
		// The legacy timestamp trigger coerces invalid text to a valid ms value.
		// Canonical SQL reads created_at_ms; i64::MAX exceeds chrono's range.
		sql += `UPDATE threads SET created_at_ms=9223372036854775807;`
	}
	seedClose := sqliteFixture(t, seed, true, sql)
	seedClosed := false
	defer func() {
		if !seedClosed {
			seedClose()
		}
	}()
	walOnly := *backendMode == "wal-only" || *backendMode == "stale-shm"
	if !walOnly {
		seedClose()
		seedClosed = true
	}
	source := filepath.Join(sourceHome, "state_5.sqlite")
	for _, suffix := range []string{"", "-wal"} {
		b, e := readBounded(filepath.Join(seed, "state_5.sqlite")+suffix, limit)
		if os.IsNotExist(e) && suffix == "-wal" {
			continue
		}
		if e != nil {
			t.Fatal(e)
		}
		if e := createFile(source+suffix, b); e != nil {
			t.Fatal(e)
		}
	}
	if !seedClosed {
		seedClose()
		seedClosed = true
	}
	if *backendMode == "empty-wal" {
		if e := createFile(source+"-wal", nil); e != nil {
			t.Fatal(e)
		}
	}
	if *backendMode == "stale-shm" {
		if e := createFile(source+"-shm", []byte("owned stale source SHM")); e != nil {
			t.Fatal(e)
		}
	}
	s, e := acquireSnapshot(source, filepath.Join(root, "private"), limit, nil, nil)
	if e != nil {
		t.Fatal(e)
	}
	canCleanup := true
	defer func() {
		if !s.Closed {
			if e := s.Close(canCleanup); e != nil {
				t.Error(e)
			}
		}
	}()
	view, e := inspectPrivateState(s, []member{{ID: rootID}})
	if e != nil || !view.IDs[rootID] {
		t.Fatal("Go U-a private inspection", e)
	}
	observation := view.Observation
	if e := validateObservation(observation, source); e != nil {
		t.Fatal(e)
	}
	var expectedReason any
	switch *backendMode {
	case "decoder-error":
		expectedReason = "stateMetadataUnknown"
	case "missing-private-copy":
		if e := os.Remove(filepath.Join(s.Private, "state_5.sqlite")); e != nil {
			t.Fatal(e)
		}
		expectedReason = "acquisitionUnknown"
	case "nonempty-new-wal":
		if e := os.WriteFile(filepath.Join(s.Private, "state_5.sqlite-wal"), []byte("forbidden private WAL bytes"), 0600); e != nil {
			t.Fatal(e)
		}
		expectedReason = "acquisitionUnknown"
	case "unknown-entry":
		if e := createFile(filepath.Join(s.Private, "unknown-entry"), []byte("retain for attention")); e != nil {
			t.Fatal(e)
		}
		expectedReason = "acquisitionUnknown"
	}
	manifest := object{"schemaVersion": 1, "caseId": *backendCaseID, "dbObservation": observation, "threadIds": []string{rootID, otherID}, "expectedReason": expectedReason}
	manifestPath := filepath.Join(root, "manifest.json")
	if e := createFile(manifestPath, append(encoded(manifest), '\n')); e != nil {
		t.Fatal(e)
	}
	// Only the pinned test process receives the manifest. Bounded execution does
	// not relax production guard or launch the protected/vendor engine.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, backendTestExe, "--ignored", "--exact", backendSelector, "--nocapture")
	cmd.Dir = root
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	for _, env := range os.Environ() {
		key, _, _ := strings.Cut(env, "=")
		if !strings.EqualFold(key, "CTXHOP_R45_BACKEND_MANIFEST") {
			cmd.Env = append(cmd.Env, env)
		}
	}
	cmd.Env = append(cmd.Env, "CTXHOP_R45_BACKEND_MANIFEST="+manifestPath)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	canCleanup = false
	runErr := cmd.Run()
	if e := createFile(filepath.Join(root, "rust-test.log"), output.Bytes()); e != nil {
		t.Fatal(e)
	}
	if runErr != nil {
		t.Fatal("pinned Rust acquisition test failed; private retained for attention", runErr)
	}
	canCleanup = true
	b, e := readBounded(filepath.Join(root, "rust-backend-receipt.json"), lineLimit)
	if e != nil {
		t.Fatal(e)
	}
	raw, e := parseJSON(b)
	if e != nil {
		t.Fatal(e)
	}
	receipt := obj(raw)
	version, vok := integer(receipt["schemaVersion"])
	if !exact(receipt, "schemaVersion", "caseId", "acquisitionId", "sourceStateDb", "privateStateDb", "reason", "rows", "scope") || !vok || version != 1 || receipt["caseId"] != *backendCaseID || receipt["acquisitionId"] != s.ID || !samePath(text(receipt["sourceStateDb"]), s.Source) || !samePath(text(receipt["privateStateDb"]), filepath.Join(s.Private, "state_5.sqlite")) || receipt["reason"] != expectedReason {
		t.Fatal("Rust receipt binding mismatch")
	}
	if expectedReason == nil {
		rows := array(receipt["rows"])
		if len(rows) != 2 || obj(rows[0])["id"] != rootID || rows[1] != nil || !hashRE.MatchString(text(obj(rows[0])["canonicalMetadataSha256"])) {
			t.Fatal("Rust canonical present/missing rows mismatch")
		}
	}
	privateErr := s.VerifyPrivate()
	if *backendMode == "missing-private-copy" || *backendMode == "nonempty-new-wal" {
		if privateErr == nil {
			t.Fatal("Go private effect rejection missing")
		}
	} else if privateErr != nil {
		t.Fatal(privateErr)
	}
	if e := s.Verify(limit); e != nil {
		t.Fatal(e)
	}
	cleanupErr := s.Close(true)
	if *backendMode == "unknown-entry" {
		if cleanupErr == nil {
			t.Fatal("unknown private entry cleanup accepted")
		}
		if _, e := os.Stat(filepath.Join(s.Private, "unknown-entry")); e != nil {
			t.Fatal("unknown entry was not retained", e)
		}
	} else {
		if cleanupErr != nil {
			t.Fatal(cleanupErr)
		}
		if e := s.VerifyReleasedSource(); e != nil {
			t.Fatal(e)
		}
	}
	result := object{"schemaVersion": 1, "caseId": *backendCaseID, "case": *backendMode, "acquisitionId": s.ID, "manifestSha256": digest(append(encoded(manifest), '\n')), "rustReceiptSha256": digest(b), "rustTestExeSha256": backendTestSHA, "rustArtifactSha256": backendArtifactSHA, "goPrivateBackend": view.Backend, "engineExecutions": 0, "sourceSQLiteOpens": 0, "sourceMainWALSHMPreserved": true, "sourceHandlesDrained": s.Closed, "privateRemoved": s.PrivateRemoved, "negativeCase": expectedReason != nil || cleanupErr != nil, "absoluteWriterExclusion": false, "scope": "same private acquisition Go inspection and canonical Rust read helper; runtime admission untested"}
	if e := createFile(filepath.Join(root, "go-backend-receipt.json"), append(encoded(result), '\n')); e != nil {
		t.Fatal(e)
	}
	t.Logf("owned case %s Go private backend %v; Rust reason=%v; source lease drained=%t; private removed=%t; actual engine=0", root, view.Backend, expectedReason, s.Closed, s.PrivateRemoved)
}
