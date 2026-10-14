//go:build windows

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHistoricalExpiryMatchesLiveWireFormatWithoutCurrentExpiry(t *testing.T) {
	for _, variant := range []struct {
		name     string
		value    any
		accepted bool
	}{
		{"null", nil, true},
		{"past-RFC3339", "2000-01-01T00:00:00Z", true},
		{"future-RFC3339", "2099-01-01T00:00:00+09:00", true},
		{"integer", json.Number("946684800"), false},
		{"negative-integer", json.Number("-1"), false},
		{"fraction", json.Number("946684800.5"), false},
		{"bool", true, false},
		{"object", object{"expiresAt": "2000-01-01T00:00:00Z"}, false},
		{"array", []any{"2000-01-01T00:00:00Z"}, false},
		{"empty-string", "", false},
		{"numeric-string", "946684800", false},
		{"malformed-string", "2000-13-01T00:00:00Z", false},
		{"missing-offset", "2000-01-01T00:00:00", false},
	} {
		t.Run(variant.name, func(t *testing.T) {
			o, j := pendingHistoricalCleanup(t, "rolled_back", true, true)
			p := j.LocalFinalization.TerminalProof
			obj(p["validity"])["expiresAt"] = variant.value
			p["projectionDigest"], _ = selfDigest(p, "projectionDigest")
			resignHistoricalReceipt(t, o, j)
			oldPrepare, oldState, oldPrepared, oldGuard := prepareEngine, readState, readPreparedState, checkGuard
			t.Cleanup(func() {
				prepareEngine, readState, readPreparedState, checkGuard = oldPrepare, oldState, oldPrepared, oldGuard
			})
			prepareEngine = func(options, string, []member) (*session, error) {
				t.Fatal("historical expiry launched engine")
				return nil, nil
			}
			readState = func(string, string, []member, bool) (dbView, error) {
				t.Fatal("historical expiry read DB")
				return dbView{}, nil
			}
			readPreparedState = readState
			checkGuard = func(*process) error { t.Fatal("historical expiry requested guard"); return nil }
			for _, row := range recoveryCLIRows(t, o.Home, o.Run) {
				if row.CanFinalizeLocal != variant.accepted {
					t.Fatal("expiry type changed cleanup capability", row)
				}
				if !variant.accepted && (row.AbsenceKind != nil || len(row.RetainedKinds) != 0) {
					t.Fatal("invalid expiry emitted absence", row)
				}
			}
			result, err := finalizeLocal(o.Home, o.Run)
			if variant.accepted {
				if err != nil || result["status"] != "rolled_back" {
					t.Fatal("supported historical timestamp rejected", result, err)
				}
			} else {
				assertCode(t, err, "finalization_binding")
				stored, err := loadJournal(o.Home, o.Run)
				if err != nil || stored.Status != "pending" || stored.LocalFinalization.State != "cleanup_pending" {
					t.Fatal("unsupported expiry changed terminal state", stored, err)
				}
			}
		})
	}
}

func TestHistoricalLoaderRequiresLiveContractSuffix(t *testing.T) {
	_, j := pendingHistoricalCleanup(t, "rolled_back", false, false)
	p := j.LocalFinalization.TerminalProof
	j.LoaderContractID = "ctxhop-prestart-v2:"
	p["loaderContractId"] = j.LoaderContractID
	p["projectionDigest"], _ = selfDigest(p, "projectionDigest")
	assertCode(t, validateHistoricalProjection(p, j, "rolled_back"), "finalization_binding")
}

func pendingHistoricalCleanup(t *testing.T, target string, reference, recovery bool) (options, *journal) {
	t.Helper()
	o, f, owner := approvalFixture(t)
	run := runPath(o.Home, o.Run)
	j := &journal{Version: 4, Impl: "ctxhop-codex", Status: "pending", Phase: "placed", Home: o.Home, Cwd: o.Cwd, ID: f.Members[0].ID, Members: f.Members, ArchiveSHA256: f.ArchiveSHA, EngineVersion: "0.159.2", EngineSHA256: engineSHA256, NormalEngineSHA256: normalEngineSHA256, LoaderContractID: loaderContractID, ApprovalEvidence: o.ApprovalEvidence, ApprovalOwnership: owner}
	if reference {
		ref := o
		ref.Home, ref.ApprovalEvidence = filepath.Join(run, "ref"), nil
		var err error
		j.ReferenceApprovalEvidence, j.ReferenceApprovalOwnership, err = createApproval(ref, f)
		if err != nil {
			t.Fatal(err)
		}
	}
	if recovery {
		m := f.Members[0]
		rid := "44444444-4444-4444-8444-444444444444"
		origin := strings.Replace(m.OriginBasename, m.ID, rid, 1) + ".zst"
		path := filepath.Join(o.Home, "sessions", origin)
		raw := []byte("opaque historical recovery fixture")
		if err := createFile(path, raw); err != nil {
			t.Fatal(err)
		}
		var err error
		o.RecoveryEvidence, err = persistRecovery(o, f.Members, []recoveryRollout{{m.ID, m.SessionID, rid, origin, m.Parent, nil, approvalSource{path, int64(len(raw)), digest(raw)}}})
		if err != nil {
			t.Fatal(err)
		}
		j.RecoveryEvidence = o.RecoveryEvidence
	}
	op := "rollback-check"
	if target == "complete" {
		op = "cold"
		for _, m := range f.Members {
			if err := createFile(m.Path, m.Raw); err != nil {
				t.Fatal(err)
			}
		}
	}
	p := projection(o, op, f.Members, true)
	if o.RecoveryEvidence != nil {
		p["recoveryEvidenceDigest"] = o.RecoveryEvidence.ManifestSHA256
	}
	observation := mockStoreObservation(text(p["stateDb"]), strings.Repeat("a", 64), nil)
	mockStoreCompleted(t, p, observation, f.Members)
	// Full production projection validation, native immutable input checks and
	// typed protocol counts; this is not an actual8/provider or engine witness.
	if err := validateProjection(p, "nonce", op, o, f.Members, 123, observation); err != nil {
		t.Fatal(err)
	}
	j.TerminalProof = p
	if err := saveJournal(run, j, true); err != nil {
		t.Fatal(err)
	}
	old := finalizationSaveJournal
	finalizationSaveJournal = func(path string, j *journal, initial bool) error {
		if j.LocalFinalization.State == "complete" {
			return fail("injected", "terminal save")
		}
		return old(path, j, initial)
	}
	err := beginFinalization(run, j, target)
	finalizationSaveJournal = old
	assertCode(t, err, "injected")
	j, err = loadJournal(o.Home, o.Run)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(filepath.Join(run, "approval", "members", "0000.jsonl")); !os.IsNotExist(err) {
		t.Fatal("source cleanup not exercised", err)
	}
	return o, j
}

func resignHistoricalReceipt(t *testing.T, o options, j *journal) {
	t.Helper()
	p := j.LocalFinalization.TerminalProof
	b, err := os.ReadFile(j.LocalFinalization.ReceiptPath)
	if err != nil {
		t.Fatal(err)
	}
	v, _ := parseJSON(b)
	r := obj(v)
	r["terminalProofDigest"], _ = terminalDigest(p)
	r["receiptDigest"], _ = selfDigest(r, "receiptDigest")
	b = encoded(r)
	if err = os.WriteFile(j.LocalFinalization.ReceiptPath, b, 0600); err != nil {
		t.Fatal(err)
	}
	j.LocalFinalization.ReceiptSHA256, j.LocalFinalization.ReceiptDigest = digest(b), text(r["receiptDigest"])
	if err = saveJournal(runPath(o.Home, o.Run), j, false); err != nil {
		t.Fatal(err)
	}
}

func TestHistoricalCompletedProjectionSourceLessRestarts(t *testing.T) {
	for _, target := range []string{"complete", "rolled_back"} {
		for _, reference := range []bool{false, true} {
			t.Run(target+map[bool]string{false: "", true: "-reference-recovery"}[reference], func(t *testing.T) {
				o, j := pendingHistoricalCleanup(t, target, reference, reference)
				obj(j.LocalFinalization.TerminalProof["validity"])["expiresAt"] = "2000-01-01T00:00:00Z"
				j.LocalFinalization.TerminalProof["projectionDigest"], _ = selfDigest(j.LocalFinalization.TerminalProof, "projectionDigest")
				resignHistoricalReceipt(t, o, j)
				oldPrepare, oldState, oldPrepared, oldGuard := prepareEngine, readState, readPreparedState, checkGuard
				t.Cleanup(func() {
					prepareEngine, readState, readPreparedState, checkGuard = oldPrepare, oldState, oldPrepared, oldGuard
				})
				prepareEngine = func(options, string, []member) (*session, error) {
					t.Fatal("historical cleanup engine call")
					return nil, nil
				}
				readState = func(string, string, []member, bool) (dbView, error) {
					t.Fatal("historical cleanup DB call")
					return dbView{}, nil
				}
				readPreparedState = readState
				checkGuard = func(*process) error { t.Fatal("historical cleanup guard"); return nil }
				result, err := finalizeLocal(o.Home, o.Run)
				if err != nil || result["status"] != target {
					t.Fatal(result, err)
				}
				if _, err = finalizeLocal(o.Home, o.Run); err != nil {
					t.Fatal("terminal idempotence", err)
				}
			})
		}
	}
}

func TestHistoricalProjectionSemanticNegatives(t *testing.T) {
	o, j := pendingHistoricalCleanup(t, "rolled_back", true, true)
	base := j.LocalFinalization.TerminalProof
	mutations := map[string]func(object){
		"version":         func(p object) { p["contractVersion"] = num(1) },
		"processId":       func(p object) { p["processId"] = num(0) },
		"generation":      func(p object) { p["generation"] = num(0) },
		"requestNonce":    func(p object) { p["requestNonce"] = "" },
		"processNonce":    func(p object) { p["processNonce"] = "" },
		"snapshotId":      func(p object) { p["snapshotId"] = "" },
		"engineVersion":   func(p object) { p["engineVersion"] = "0.159.3" },
		"loader":          func(p object) { p["loaderContractId"] = "ctxhop-prestart-v2:foreign" },
		"incomplete":      func(p object) { p["inputComplete"] = false },
		"redirect":        func(p object) { p["sqliteRedirect"] = true },
		"home":            func(p object) { p["home"] = o.Cwd },
		"normalHome":      func(p object) { p["normalSqliteHome"] = o.Cwd },
		"operationHome":   func(p object) { p["operationSqliteHome"] = o.Cwd },
		"stateDb":         func(p object) { p["stateDb"] = filepath.Join(o.Home, "logs_2.sqlite") },
		"proofTargets":    func(p object) { a := array(p["proofTargets"]); a[0], a[1] = a[1], a[0] },
		"writeTargets":    func(p object) { obj(array(p["writeTargets"])[0])["path"] = o.Cwd },
		"effects":         func(p object) { obj(p["effects"])["applicationWrites"] = num(1) },
		"network":         func(p object) { obj(p["effects"])["networkRequests"] = num(1) },
		"shm":             func(p object) { obj(p["effects"])["sqliteShmMayChange"] = true },
		"privateSidecars": func(p object) { obj(p["effects"])["privateSqliteSidecarsMayChange"] = false },
		"auth":            func(p object) { p["authResolution"] = "unknown" },
		"policy":          func(p object) { p["policyResolution"] = "unknown" },
		"validity":        func(p object) { obj(p["validity"])["expiresAt"] = "invalid" },
		"projectConfig": func(p object) {
			p["projectConfig"] = []any{object{"path": "relative", "applied": true, "warning": nil}}
		},
		"profile":         func(p object) { p["mappingProfile"] = "unknown" },
		"approval":        func(p object) { p["approvalEvidenceDigest"] = strings.Repeat("0", 64) },
		"mapping":         func(p object) { p["approvedMappingDigest"] = strings.Repeat("0", 64) },
		"recovery":        func(p object) { p["recoveryEvidenceDigest"] = nil },
		"acquisition":     func(p object) { p["acquisitionId"] = nil },
		"observation":     func(p object) { p["storeObservationDigest"] = strings.Repeat("0", 64) },
		"storeProof":      func(p object) { delete(obj(p["storeProof"]), "members") },
		"context-missing": func(p object) { p["contexts"] = array(p["contexts"])[:1] },
		"context-order":   func(p object) { a := array(p["contexts"]); a[1], a[2] = a[2], a[1] },
		"context-owner":   func(p object) { obj(array(p["contexts"])[2])["ownerId"] = j.Members[0].ID },
		"context-phase": func(p object) {
			c := obj(array(p["contexts"])[1])
			c["phase"] = "firstResume"
			c["rolloutSha256"] = j.Members[0].SHA256
			c["settingsDigest"] = strings.Repeat("a", 64)
		},
		"context-cwd":    func(p object) { obj(array(p["contexts"])[1])["cwd"] = o.Home },
		"context-sqlite": func(p object) { obj(array(p["contexts"])[1])["sqliteHome"] = o.Cwd },
		"context-id":     func(p object) { obj(array(p["contexts"])[1])["contextId"] = "startup" },
		"startup":        func(p object) { obj(array(p["contexts"])[0])["memberId"] = j.ID },
	}
	mutations["empty-retained-marker"] = func(p object) { obj(array(p["contexts"])[1])["phase"] = "rollbackRetained" }
	mutations["passive-under-absent"] = func(p object) {
		for _, v := range array(obj(array(obj(p["storeProof"])["members"])[0])["relations"]) {
			r := obj(v)
			if passiveFinalizationKind(text(r["kind"]) + "." + text(r["relationClass"])) {
				obj(r["counts"])["passive"] = num(1)
			}
		}
	}
	for key := range base {
		key := key
		mutations["missing-"+key] = func(p object) { delete(p, key) }
	}
	for name, mutation := range mutations {
		t.Run(name, func(t *testing.T) {
			j.LocalFinalization.TerminalProof = obj(cloneJSON(base))
			mutation(j.LocalFinalization.TerminalProof)
			if name != "missing-projectionDigest" {
				j.LocalFinalization.TerminalProof["projectionDigest"], _ = selfDigest(j.LocalFinalization.TerminalProof, "projectionDigest")
			}
			resignHistoricalReceipt(t, o, j)
			if _, err := finalizeLocal(o.Home, o.Run); err == nil {
				t.Fatal("hash-consistent semantic invalid proof accepted", name)
			}
			for _, row := range recoveryCLIRows(t, o.Home, o.Run) {
				if row.CanFinalizeLocal || row.AbsenceKind != nil {
					t.Fatal("invalid proof created absence/cleanup", row)
				}
			}
		})
	}
}

func TestHistoricalRetainedAndMixedMarkersSourceLess(t *testing.T) {
	for _, variant := range []string{"full-retained", "mixed-absent-retained", "wrong-absent-phase", "wrong-retained-phase"} {
		t.Run(variant, func(t *testing.T) {
			o, j := pendingHistoricalCleanup(t, "rolled_back", true, true)
			p := j.LocalFinalization.TerminalProof
			allowed := []string{"state.migrationCursor", "queue.revision", "agentMessageBoard.deletedBoard"}
			for i, row := range array(obj(p["storeProof"])["members"]) {
				if variant == "mixed-absent-retained" && i == 0 {
					continue
				}
				for _, v := range array(obj(row)["relations"]) {
					r := obj(v)
					if passiveFinalizationKind(text(r["kind"]) + "." + text(r["relationClass"])) {
						obj(r["counts"])["passive"] = num(1)
					}
				}
				obj(array(p["contexts"])[i+1])["phase"] = "rollbackRetained"
			}
			if variant == "wrong-absent-phase" {
				obj(array(p["contexts"])[1])["phase"] = "rollbackAbsent"
			}
			if variant == "wrong-retained-phase" {
				for _, v := range array(obj(array(obj(p["storeProof"])["members"])[0])["relations"]) {
					obj(obj(v)["counts"])["passive"] = num(0)
				}
			}
			p["projectionDigest"], _ = selfDigest(p, "projectionDigest")
			j.LocalFinalization.AbsenceKind, j.LocalFinalization.RetainedKinds = pointer("retained"), allowed
			resignHistoricalReceipt(t, o, j)
			// Pure stored metadata fixture. Live retained/mixed admission remains
			// blocked pending the actual canonical provider/runtime gates.
			result, err := finalizeLocal(o.Home, o.Run)
			if strings.HasPrefix(variant, "wrong-") {
				if err == nil {
					t.Fatal("marker/count semantics mismatch accepted")
				}
				return
			}
			if err != nil || result["status"] != "rolled_back" {
				t.Fatal(result, err)
			}
			for _, row := range recoveryCLIRows(t, o.Home, o.Run) {
				if row.AbsenceKind == nil || *row.AbsenceKind != "retained" || len(row.RetainedKinds) != 3 {
					t.Fatal(row)
				}
			}
		})
	}
}

func TestHistoricalCompactRecoveryRejectsResignedUnknownVersion(t *testing.T) {
	o, j := pendingHistoricalCleanup(t, "rolled_back", true, true)
	path := j.RecoveryEvidence.ManifestPath
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	v, err := parseJSON(b)
	if err != nil {
		t.Fatal(err)
	}
	obj(v)["schemaVersion"] = num(2)
	b = encoded(v)
	if err = os.WriteFile(path, b, 0600); err != nil {
		t.Fatal(err)
	}
	j.RecoveryEvidence.ManifestSHA256 = digest(b)
	p := j.LocalFinalization.TerminalProof
	p["recoveryEvidenceDigest"] = digest(b)
	p["projectionDigest"], _ = selfDigest(p, "projectionDigest")
	resignHistoricalReceipt(t, o, j)
	b, err = os.ReadFile(j.LocalFinalization.ReceiptPath)
	if err != nil {
		t.Fatal(err)
	}
	v, err = parseJSON(b)
	if err != nil {
		t.Fatal(err)
	}
	r := obj(v)
	r["recoveryEvidenceDigest"] = j.RecoveryEvidence.ManifestSHA256
	r["receiptDigest"], _ = selfDigest(r, "receiptDigest")
	b = encoded(r)
	if err = os.WriteFile(j.LocalFinalization.ReceiptPath, b, 0600); err != nil {
		t.Fatal(err)
	}
	j.LocalFinalization.ReceiptSHA256, j.LocalFinalization.ReceiptDigest = digest(b), text(r["receiptDigest"])
	if err = saveJournal(runPath(o.Home, o.Run), j, false); err != nil {
		t.Fatal(err)
	}
	if _, err = finalizeLocal(o.Home, o.Run); err == nil {
		t.Fatal("hash-consistent unknown compact recovery version accepted")
	}
}
