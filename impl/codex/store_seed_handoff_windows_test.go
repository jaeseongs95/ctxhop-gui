//go:build windows && ctxhop_store_seed

package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

const seedSchemaSelector = "prestart_context::store_provider::schema_reader::tests::validate_canonical_schema_from_owned_handoff"
const seedSchemaSHA = "6cad182f2f78614d5b239b56d5326c497e41e8a6e2b558b40d6ef5a3c9179067"
const seedAcquisitionOwner = "01a0f1f9-e123-7460-847d-1bc68f56a487"

var storeSeedOutput = flag.String("ctxhop-store-seed-output", "", "new runner-owned handoff output")
var storeSeedReader = flag.String("ctxhop-store-seed-reader", "", "pinned Rust libtest executable; fixture only")
var storeSeedReaderSHA = flag.String("ctxhop-store-seed-reader-sha256", "", "reviewed Rust executable SHA256")
var storeSeedReaderCwd = flag.String("ctxhop-store-seed-reader-cwd", "", "reviewed Rust libtest working directory")
var storeSeedCancelPoint = flag.String("ctxhop-store-seed-cancel-point", "", "fixture-only expected reader cancellation point")

func validSeedCancelPoint(point string) bool {
	return point == "afterReaders" || point == "duringDrain" || point == "beforeReceipt"
}

func validateSeedHandoffOutput(path string) error {
	base := `D:\Go\codex-s4`
	if !filepath.IsAbs(path) || !samePath(filepath.Dir(path), base) || !strings.HasPrefix(filepath.Base(path), "run-helper2-r45-") || !opRE.MatchString(strings.TrimPrefix(filepath.Base(path), "run-helper2-r45-")) {
		return fmt.Errorf("handoff requires a new owned runner output")
	}
	entry, e := snapshotOpen(path, true)
	if e != nil {
		return e
	}
	return entry.File.Close()
}

type seedPipeResult struct {
	name string
	data []byte
	err  error
}

// This fixture owns the launch Job. Neither a marker nor a reader receipt can
// substitute for the kernel's whole-Job drain observation.
func runSeedJob(image, dir string, env, args []string, timeout time.Duration) (receipt object, drained bool, retErr error) {
	p, e := startProcessArgs(image, dir, env, args)
	if e != nil {
		return nil, true, e // the suspended-launch helper has drained its failed launch
	}
	receipt = object{"pid": int64(p.PID), "creationTime": fmt.Sprint(p.Created), "image": p.Image, "jobActiveProcesses": nil, "exitCode": nil, "handlesClosed": false, "transportVerified": false}
	defer func() {
		// KILL_ON_JOB_CLOSE is a cancellation attempt, never proof of drain.
		if !p.closed {
			retErr = errors.Join(retErr, p.In.Close(), p.Out.Close(), p.Err.Close(), syscall.CloseHandle(p.handle), syscall.CloseHandle(p.job))
		}
	}()
	if e := p.In.Close(); e != nil {
		return receipt, false, e
	}
	outputs := make(chan seedPipeResult, 2)
	for _, stream := range []struct {
		name string
		file *os.File
	}{{"stdout", p.Out}, {"stderr", p.Err}} {
		go func(name string, file *os.File) {
			b, e := io.ReadAll(io.LimitReader(file, (1<<20)+1))
			if len(b) > 1<<20 {
				e = errors.Join(e, fmt.Errorf("reader %s exceeds 1MiB", name))
			}
			outputs <- seedPipeResult{name, b, e}
		}(stream.name, stream.file)
	}
	deadline := time.Now().Add(timeout)
	stopping := false
	collected := 0
	for {
		select {
		case output := <-outputs:
			collected++
			receipt[output.name] = string(output.data)
			retErr = errors.Join(retErr, output.err)
		default:
		}
		active, e := p.active()
		if e != nil {
			return receipt, false, errors.Join(retErr, e)
		}
		var exit uint32
		if e := syscall.GetExitCodeProcess(p.handle, &exit); e != nil {
			return receipt, false, errors.Join(retErr, e)
		}
		if active == 0 && exit != 259 {
			drained = true
			receipt["jobActiveProcesses"], receipt["exitCode"] = int64(active), int64(exit)
			if collected == 2 {
				break
			}
		}
		if !stopping && (retErr != nil || time.Now().After(deadline)) {
			retErr = errors.Join(retErr, fmt.Errorf("reader canceled or deadline exceeded"))
			r, _, e := proc("TerminateJobObject").Call(uintptr(p.job), 1)
			if r == 0 {
				return receipt, false, errors.Join(retErr, e)
			}
			stopping = true
			deadline = time.Now().Add(5 * time.Second)
		}
		if stopping && time.Now().After(deadline) {
			return receipt, drained, errors.Join(retErr, fmt.Errorf("reader drain/output deadline exceeded"))
		}
		time.Sleep(10 * time.Millisecond)
	}
	closeErr := errors.Join(p.Out.Close(), p.Err.Close(), syscall.CloseHandle(p.handle), syscall.CloseHandle(p.job))
	p.closed = true
	receipt["handlesClosed"] = closeErr == nil
	receipt["transportVerified"] = retErr == nil && closeErr == nil
	var exitErr error
	if exit, ok := receipt["exitCode"].(int64); !ok || exit != 0 {
		exitErr = fmt.Errorf("reader exit %v", receipt["exitCode"])
	}
	return receipt, drained, errors.Join(retErr, closeErr, exitErr)
}

func handoffSeedSchema(s *storeAcquisition, observation, proof object) (drained bool, retErr error) {
	drained = true // no external process exists until the direct owned launch below
	point := *storeSeedCancelPoint
	if point != "" && !validSeedCancelPoint(point) {
		return drained, fmt.Errorf("unknown fixture cancellation point")
	}
	if !filepath.IsAbs(*storeSeedReader) || !strings.HasPrefix(strings.ToLower(filepath.Clean(*storeSeedReader)), `d:\go\codex-s4\`) || !hashRE.MatchString(*storeSeedReaderSHA) {
		return drained, fmt.Errorf("fixture reader path/hash pin required")
	}
	locks, e := lockImage(*storeSeedReader)
	if e != nil {
		return drained, e
	}
	defer func() {
		for _, f := range locks {
			retErr = errors.Join(retErr, f.Close())
		}
	}()
	actual, _, e := snapshotHash(locks[0], limit)
	if e != nil || actual != *storeSeedReaderSHA {
		return drained, errors.Join(e, fmt.Errorf("fixture reader executable pin mismatch"))
	}
	observationDigest, e := validateStoreObservationV2(observation, s.SourceRoot, s.targets)
	if e != nil {
		return drained, e
	}
	manifest := object{"schemaVersion": int64(2), "ownerSessionId": seedAcquisitionOwner, "schemaSha256": seedSchemaSHA, "storeObservation": observation}
	manifestBytes := append(encoded(manifest), '\n')
	if len(manifestBytes) > 1<<20 {
		return drained, fmt.Errorf("handoff manifest exceeds 1MiB")
	}
	manifestPath := filepath.Join(*storeSeedOutput, "schema-handoff.json")
	if e := createFile(manifestPath, manifestBytes); e != nil {
		return drained, e
	}
	ownership := object{"schemaVersion": int64(2), "ownerSessionId": seedAcquisitionOwner, "runNonce": nonce(), "acquisitionId": s.ID, "storeObservationDigest": observationDigest, "handoffSha256": digest(manifestBytes), "readerSha256": actual, "storeObservation": observation, "storeProof": proof, "mappingAuthority": "syntheticFixtureOnly", "sourceLeasesHeld": true}
	ownership["expectedCancellationPoint"] = point
	if e := createFile(filepath.Join(*storeSeedOutput, "go-ownership-receipt.json"), append(encoded(ownership), '\n')); e != nil {
		return drained, e
	}
	env := []string{}
	for _, value := range os.Environ() {
		key, _, _ := strings.Cut(value, "=")
		if !strings.HasPrefix(strings.ToUpper(key), "CTXHOP_") && !strings.EqualFold(key, "RUST_TEST_THREADS") {
			env = append(env, value)
		}
	}
	env = append(env, "CTXHOP_S4_SCHEMA_HANDOFF_PATH="+manifestPath, "CTXHOP_S4_SCHEMA_HANDOFF_SHA256="+digest(manifestBytes), "RUST_TEST_THREADS=1")
	if point != "" {
		env = append(env, "CTXHOP_S4_SCHEMA_CANCEL_POINT="+point)
	}
	cwd := *storeSeedReaderCwd
	if !filepath.IsAbs(cwd) || !strings.HasPrefix(strings.ToLower(filepath.Clean(cwd)), `d:\go\codex-s4\`) {
		return drained, fmt.Errorf("reviewed Rust fixture working directory required")
	}
	jobReceipt, drained, runErr := runSeedJob(*storeSeedReader, cwd, env, []string{"--ignored", "--exact", seedSchemaSelector, "--nocapture"}, 60*time.Second)
	if jobReceipt != nil {
		jobReceipt["workingDirectory"] = cwd
	}
	writeErr := createFile(filepath.Join(*storeSeedOutput, "go-reader-job-receipt.json"), append(encoded(jobReceipt), '\n'))
	if writeErr != nil || !drained || jobReceipt["transportVerified"] != true {
		return drained, errors.Join(runErr, writeErr, fmt.Errorf("whole reader Job must drain before source release"))
	}
	if point != "" {
		if runErr == nil || jobReceipt["exitCode"] == int64(0) {
			return drained, fmt.Errorf("expected cancellation must fail the reader process")
		}
		if e := snapshotAbsent(filepath.Join(*storeSeedOutput, "rust-schema-receipt.json")); e != nil {
			return drained, fmt.Errorf("canceled reader emitted a success receipt: %w", e)
		}
		b, e := readBounded(filepath.Join(*storeSeedOutput, "rust-schema-negative-receipt.json"), 1<<20)
		if e != nil {
			return drained, e
		}
		v, e := parseJSON(b)
		if e != nil {
			return drained, e
		}
		if e := validateSeedCancelReceipt(obj(v), s.ID, observationDigest, digest(manifestBytes), point); e != nil {
			return drained, e
		}
		return drained, s.Verify()
	}
	if runErr != nil {
		return drained, runErr
	}
	b, e := readBounded(filepath.Join(*storeSeedOutput, "rust-schema-receipt.json"), 1<<20)
	if e != nil {
		return drained, e
	}
	v, e := parseJSON(b)
	if e != nil {
		return drained, e
	}
	if e := validateSeedSchemaReceipt(obj(v), s.ID, observationDigest, digest(manifestBytes)); e != nil {
		return drained, e
	}
	return drained, s.Verify()
}

func validateSeedSchemaReceipt(receipt object, acquisitionID, observationDigest, handoffDigest string) error {
	version, ok := integer(receipt["schemaVersion"])
	originalOpens, originalOK := integer(receipt["originalSQLiteOpens"])
	if !exact(receipt, "schemaVersion", "schemaSha256", "acquisitionId", "observationDigest", "verifiedKinds", "readersDrained", "sidecarVerified", "nativeClosed", "originalSQLiteOpens", "ownerSessionId", "readerSessionId", "handoffSha256") || !ok || version != 2 || !originalOK || originalOpens != 0 || receipt["schemaSha256"] != seedSchemaSHA || receipt["acquisitionId"] != acquisitionID || receipt["observationDigest"] != observationDigest || receipt["readersDrained"] != true || receipt["sidecarVerified"] != true || receipt["nativeClosed"] != true || receipt["ownerSessionId"] != seedAcquisitionOwner || receipt["readerSessionId"] != "01a0f1ed-e575-7123-9c78-be9aa4802005" || receipt["handoffSha256"] != handoffDigest {
		return fmt.Errorf("Rust schema receipt binding/drain mismatch")
	}
	kinds := array(receipt["verifiedKinds"])
	if len(kinds) != len(storeSpecs) {
		return fmt.Errorf("Rust present store vector length mismatch")
	}
	for i, spec := range storeSpecs {
		if kinds[i] != spec.Kind {
			return fmt.Errorf("Rust present store vector order mismatch")
		}
	}
	return nil
}

func validateSeedCancelReceipt(receipt object, acquisitionID, observationDigest, handoffDigest, point string) error {
	if !validSeedCancelPoint(point) || !exact(receipt, "schemaVersion", "schemaSha256", "acquisitionId", "observationDigest", "verifiedKinds", "readersDrained", "sidecarVerified", "nativeClosed", "originalSQLiteOpens", "ownerSessionId", "readerSessionId", "handoffSha256", "outcome", "cancelPoint", "reason", "completedProof") || receipt["outcome"] != "canceled" || receipt["cancelPoint"] != point || receipt["reason"] != "storeReadCancelled" || receipt["completedProof"] != false {
		return fmt.Errorf("expected cancellation receipt mismatch")
	}
	common := object{}
	for key, value := range receipt {
		if key != "outcome" && key != "cancelPoint" && key != "reason" && key != "completedProof" {
			common[key] = value
		}
	}
	return validateSeedSchemaReceipt(common, acquisitionID, observationDigest, handoffDigest)
}

func TestStoreSeedReaderJobChild(t *testing.T) {
	switch os.Getenv("CTXHOP_SEED_JOB_CHILD") {
	case "success":
		fmt.Print("owned child output")
	case "failure":
		os.Exit(7)
	case "overflow":
		fmt.Print(strings.Repeat("x", (1<<20)+100))
	case "timeout":
		time.Sleep(time.Minute)
	case "descendant":
		child := exec.Command(os.Args[0], "-test.run=^TestStoreSeedReaderJobChild$")
		child.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		for _, value := range os.Environ() {
			key, _, _ := strings.Cut(value, "=")
			if !strings.EqualFold(key, "CTXHOP_SEED_JOB_CHILD") {
				child.Env = append(child.Env, value)
			}
		}
		child.Env = append(child.Env, "CTXHOP_SEED_JOB_CHILD=timeout")
		child.Stdout, child.Stderr = os.Stdout, os.Stderr
		if e := child.Start(); e != nil {
			t.Fatal(e)
		}
		fmt.Print("owned descendant started")
		os.Exit(0) // the Job remains active; parent exit alone cannot release anything
	default:
		t.Skip("owned child selector only")
	}
}

func TestStoreSeedReaderJob(t *testing.T) {
	for _, mode := range []string{"success", "failure", "overflow", "timeout", "descendant"} {
		t.Run(mode, func(t *testing.T) {
			receipt, drained, e := runSeedJob(os.Args[0], t.TempDir(), append(os.Environ(), "CTXHOP_SEED_JOB_CHILD="+mode), []string{"-test.run=^TestStoreSeedReaderJobChild$"}, 250*time.Millisecond)
			if !drained || receipt["jobActiveProcesses"] != int64(0) || receipt["handlesClosed"] != true || (e == nil) != (mode == "success") {
				t.Fatal("Job drain/result mismatch", mode, drained, e)
			}
			if receipt["transportVerified"] != (mode == "success" || mode == "failure") {
				t.Fatal("reader nonzero exit must be distinct from monitor cancellation/overflow")
			}
			if mode == "descendant" && (receipt["exitCode"] != int64(0) || !strings.Contains(text(receipt["stdout"]), "owned descendant started")) {
				t.Fatal("parent must exit successfully while its owned descendant still requires Job cancellation")
			}
		})
	}
}

func seedSchemaReceiptFixture(t *testing.T) object {
	t.Helper()
	kinds := []any{}
	for _, spec := range storeSpecs {
		kinds = append(kinds, spec.Kind)
	}
	valid := object{"schemaVersion": int64(2), "schemaSha256": seedSchemaSHA, "acquisitionId": "owned-acquisition", "observationDigest": strings.Repeat("a", 64), "verifiedKinds": kinds, "readersDrained": true, "sidecarVerified": true, "nativeClosed": true, "originalSQLiteOpens": int64(0), "ownerSessionId": seedAcquisitionOwner, "readerSessionId": "01a0f1ed-e575-7123-9c78-be9aa4802005", "handoffSha256": strings.Repeat("b", 64)}
	wire, e := parseJSON(encoded(valid))
	if e != nil {
		t.Fatal(e)
	}
	return obj(wire) // same exact JSON integer representation as the reader response
}

func TestStoreSeedSchemaReceipt(t *testing.T) {
	valid := seedSchemaReceiptFixture(t)
	check := func(receipt object) error {
		return validateSeedSchemaReceipt(receipt, "owned-acquisition", strings.Repeat("a", 64), strings.Repeat("b", 64))
	}
	if e := check(valid); e != nil {
		t.Fatal(e)
	}
	for _, field := range []string{"acquisitionId", "observationDigest", "handoffSha256", "ownerSessionId", "readerSessionId", "schemaSha256", "verifiedKinds", "schemaVersion", "originalSQLiteOpens", "readersDrained", "sidecarVerified", "nativeClosed"} {
		t.Run(field, func(t *testing.T) {
			parsed, e := parseJSON(encoded(valid))
			if e != nil {
				t.Fatal(e)
			}
			changed := obj(parsed)
			changed[field] = nil
			if e := check(changed); e == nil {
				t.Fatal("uncertain or unbound reader receipt accepted")
			}
		})
	}
}

func TestStoreSeedCancelReceipt(t *testing.T) {
	for _, point := range []string{"afterReaders", "duringDrain", "beforeReceipt"} {
		t.Run(point, func(t *testing.T) {
			valid := seedSchemaReceiptFixture(t)
			valid["outcome"], valid["cancelPoint"], valid["reason"], valid["completedProof"] = "canceled", point, "storeReadCancelled", false
			check := func(receipt object) error {
				return validateSeedCancelReceipt(receipt, "owned-acquisition", strings.Repeat("a", 64), strings.Repeat("b", 64), point)
			}
			if e := check(valid); e != nil {
				t.Fatal(e)
			}
			for _, field := range []string{"outcome", "cancelPoint", "reason", "completedProof", "readersDrained", "nativeClosed", "verifiedKinds", "handoffSha256"} {
				changed := obj(clone(valid))
				changed[field] = nil
				if e := check(changed); e == nil {
					t.Fatal("cancellation receipt with missing binding/drain accepted", field)
				}
			}
			valid["completedProof"] = true
			if e := check(valid); e == nil {
				t.Fatal("cancellation must not certify a completed proof")
			}
		})
	}
	if e := validateSeedCancelReceipt(seedSchemaReceiptFixture(t), "owned-acquisition", strings.Repeat("a", 64), strings.Repeat("b", 64), "unknown"); e == nil {
		t.Fatal("unknown cancellation point accepted")
	}
}
