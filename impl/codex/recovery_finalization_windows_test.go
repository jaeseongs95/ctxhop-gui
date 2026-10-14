//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"unsafe"
)

func TestInitialJournalFailureOwnsOnlyNewEmptyRun(t *testing.T) {
	for _, variant := range []string{"empty", "tmp", "unknown", "replaced"} {
		t.Run(variant, func(t *testing.T) {
			o, m := importFixture(t, "legacy", false)
			old := initialJournalWrite
			t.Cleanup(func() { initialJournalWrite = old })
			initialJournalWrite = func(run string, j *journal, initial bool) error {
				if !initial {
					t.Fatal("initial write hook reused")
				}
				switch variant {
				case "tmp", "unknown":
					name := "journal.tmp"
					if variant == "unknown" {
						name = "unknown"
					}
					if err := createFile(filepath.Join(run, name), []byte("preserve")); err != nil {
						t.Fatal(err)
					}
				case "replaced":
					if err := os.Rename(run, run+"-original"); err != nil {
						t.Fatal(err)
					}
					if err := os.Mkdir(run, 0700); err != nil {
						t.Fatal(err)
					}
				}
				return fail("injected", "initial save failure")
			}
			result, err := importArchive(o)
			assertCode(t, err, "injected")
			if m.Active || m.Deletes != 0 || len(m.home(o.Home).IDs) != 0 {
				t.Fatal("initial failure caused application effects")
			}
			_, statErr := os.Stat(runPath(o.Home, o.Run))
			if variant == "empty" {
				if !os.IsNotExist(statErr) || len(result["pending"].([]string)) != 0 {
					t.Fatal(result, statErr)
				}
			} else {
				if statErr != nil || len(result["pending"].([]string)) != 1 {
					t.Fatal("nonempty/replaced run removed", result, statErr)
				}
				row, err := classifyRecoveryRecord(o.Home, o.Run)
				if err != nil || !row.BlocksImport || row.CanRollback || row.CanResolve {
					t.Fatal(row, err)
				}
			}
		})
	}
}

func TestLocalFinalizationCrashAndRestartMatrix(t *testing.T) {
	variants := []string{"receipt-save", "journal-bind", "changed-file", "unknown-child", "final-save"}
	for index := 1; index <= 6; index++ {
		variants = append(variants, fmt.Sprintf("cleanup-%d", index))
	}
	for _, variant := range variants {
		t.Run(variant, func(t *testing.T) {
			o, f, ownership := approvalFixture(t)
			run := runPath(o.Home, o.Run)
			j := &journal{Version: 4, Impl: "ctxhop-codex", Status: "pending", Phase: "staged", Home: o.Home, Cwd: o.Cwd, ID: f.Members[0].ID, Members: f.Members, ArchiveSHA256: f.ArchiveSHA, EngineSHA256: engineSHA256, NormalEngineSHA256: normalEngineSHA256, LoaderContractID: loaderContractID, ApprovalEvidence: o.ApprovalEvidence, ApprovalOwnership: ownership}
			if err := saveJournal(run, j, true); err != nil {
				t.Fatal(err)
			}
			for index, m := range f.Members {
				if err := createFile(filepath.Join(run, "stage", fmt.Sprintf("%04d.jsonl", index)), m.Raw); err != nil {
					t.Fatal(err)
				}
			}
			oldReceipt, oldSave, oldRemove := finalizationCreateReceipt, finalizationSaveJournal, finalizationRemoveEntry
			t.Cleanup(func() {
				finalizationCreateReceipt, finalizationSaveJournal, finalizationRemoveEntry = oldReceipt, oldSave, oldRemove
			})
			removed := 0
			finalizationRemoveEntry = func(path, id, sha string, size int64, directory bool) error {
				if variant == fmt.Sprintf("cleanup-%d", removed+1) {
					return fail("injected", "cleanup failure")
				}
				err := oldRemove(path, id, sha, size, directory)
				if err == nil {
					removed++
				}
				return err
			}
			if variant == "receipt-save" {
				finalizationCreateReceipt = func(string, []byte) error { return fail("injected", "receipt failure") }
			}
			finalizationSaveJournal = func(path string, value *journal, initial bool) error {
				if variant == "journal-bind" || variant == "final-save" && value.LocalFinalization.State == "complete" {
					return fail("injected", "journal failure")
				}
				if err := oldSave(path, value, initial); err != nil {
					return err
				}
				if value.LocalFinalization.State == "cleanup_pending" {
					switch variant {
					case "changed-file":
						return os.WriteFile(filepath.Join(run, "stage", "0001.jsonl"), []byte("changed"), 0600)
					case "unknown-child":
						return createFile(filepath.Join(run, "stage", "unknown"), []byte("preserve"))
					}
				}
				return nil
			}
			err := beginFinalization(run, j, "rolled_back")
			if err == nil {
				t.Fatal("injected finalization failure became success", variant)
			}
			if (variant == "receipt-save" || variant == "journal-bind" || variant == "changed-file" || variant == "unknown-child") && removed != 0 {
				t.Fatal("deleted before whole validation", removed)
			}
			stored, err := loadJournal(o.Home, o.Run)
			if err != nil || stored.Status != "pending" {
				t.Fatal("failure lost pending journal", stored, err)
			}
			finalizationCreateReceipt, finalizationSaveJournal, finalizationRemoveEntry = oldReceipt, oldSave, oldRemove
			if variant == "receipt-save" || variant == "journal-bind" {
				if stored.LocalFinalization != nil {
					t.Fatal("unbound receipt gained cleanup authority")
				}
				if _, err = finalizeLocal(o.Home, o.Run); err == nil {
					t.Fatal("unbound restart authorized cleanup")
				}
				return
			}
			if stored.LocalFinalization == nil || stored.LocalFinalization.State != "cleanup_pending" {
				t.Fatal(stored)
			}
			pendingRow, err := classifyRecoveryRecord(o.Home, o.Run)
			if err != nil || pendingRow.State != "pending" || !pendingRow.BlocksImport || !pendingRow.CanFinalizeLocal || pendingRow.CanRollback || pendingRow.CanResolve {
				t.Fatal("cleanup capability mismatch", pendingRow, err)
			}
			t.Logf("nativeRecoveryRow=%s", encoded(pendingRow))
			if variant == "changed-file" {
				if err = os.WriteFile(filepath.Join(run, "stage", "0001.jsonl"), f.Members[1].Raw, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if variant == "unknown-child" {
				if err = os.Remove(filepath.Join(run, "stage", "unknown")); err != nil {
					t.Fatal(err)
				}
			}
			oldPrepare, oldState, oldPrepared, oldGuard := prepareEngine, readState, readPreparedState, checkGuard
			defer func() {
				prepareEngine, readState, readPreparedState, checkGuard = oldPrepare, oldState, oldPrepared, oldGuard
			}()
			prepareEngine = func(options, string, []member) (*session, error) {
				t.Fatal("cleanup-only launched engine")
				return nil, nil
			}
			readState = func(string, string, []member, bool) (dbView, error) {
				t.Fatal("cleanup-only read database")
				return dbView{}, nil
			}
			readPreparedState = readState
			checkGuard = func(*process) error { t.Fatal("cleanup-only requested engine guard"); return nil }
			result, err := finalizeLocal(o.Home, o.Run)
			if err != nil || result["status"] != "rolled_back" {
				t.Fatal(result, err)
			}
			row, err := classifyRecoveryRecord(o.Home, o.Run)
			if err != nil || row.State != "rolled_back" || row.BlocksImport || row.CanFinalizeLocal || row.ReasonCode != nil || row.AbsenceKind == nil || *row.AbsenceKind != "absent" || len(row.RetainedKinds) != 0 {
				t.Fatal(row, err)
			}
		})
	}
}

func TestHistoricalFinalizationRetainedKindsUsePassiveCatalog(t *testing.T) {
	o, f, _ := approvalFixture(t)
	d := strings.Repeat("a", 64)
	proof := projection(o, "rollback", f.Members, true)
	proof["storeObservationDigest"], proof["storeProof"] = d, wireStoreProof(t, d, f.Members)
	proof["projectionDigest"], _ = selfDigest(proof, "projectionDigest")
	j := &journal{Home: o.Home, Cwd: o.Cwd, Members: f.Members, LoaderContractID: loaderContractID, ApprovalEvidence: o.ApprovalEvidence}
	absence, kinds, err := finalizationAbsence(proof, j, "rolled_back", false)
	if err != nil || absence == nil || *absence != "absent" || len(kinds) != 0 {
		t.Fatal(absence, kinds, err)
	}
	allowed := []string{"state.migrationCursor", "queue.revision", "agentMessageBoard.deletedBoard"}
	for _, variant := range []string{"allowed", "active", "foreign", "unknown-passive", "overflow"} {
		t.Run(variant, func(t *testing.T) {
			p := obj(cloneJSON(proof))
			for _, v := range array(obj(array(obj(p["storeProof"])["members"])[0])["relations"]) {
				r := obj(v)
				key := text(r["kind"]) + "." + text(r["relationClass"])
				for _, candidate := range allowed {
					if key == candidate {
						obj(r["counts"])["passive"] = num(1)
					}
				}
				if key == "state.thread" {
					switch variant {
					case "active":
						obj(r["counts"])["active"] = num(1)
					case "foreign":
						obj(r["counts"])["externalIncoming"] = num(1)
					case "unknown-passive":
						obj(r["counts"])["passive"] = num(1)
					case "overflow":
						obj(r["counts"])["passive"] = json.Number("9223372036854775808")
					}
				}
			}
			p["projectionDigest"], _ = selfDigest(p, "projectionDigest")
			obj(array(p["contexts"])[1])["phase"] = "rollbackRetained"
			p["projectionDigest"], _ = selfDigest(p, "projectionDigest")
			a, kinds, err := finalizationAbsence(p, j, "rolled_back", false)
			if variant == "allowed" {
				if err != nil || a == nil || *a != "retained" || !bytes.Equal(encoded(kinds), encoded(allowed)) {
					t.Fatal(a, kinds, err)
				}
			} else if err == nil {
				t.Fatal("active/foreign/unknown/i64-overflow became retained", variant)
			}
		})
	}
}

func recoveryCLIRows(t *testing.T, home, run string) []recoveryRecord {
	t.Helper()
	rows := []recoveryRecord{}
	for _, command := range []string{"recovery-list", "recovery-status"} {
		args := []string{command, "--home", home}
		if command == "recovery-status" {
			args = append(args, "--run", run)
		}
		output, err := cli(args)
		if err != nil {
			t.Fatal(command, err)
		}
		wire := obj(cloneJSON(output))
		var raw object
		if command == "recovery-list" {
			if !exact(wire, "records") || len(array(wire["records"])) != 1 {
				t.Fatal(command, wire)
			}
			raw = obj(array(wire["records"])[0])
		} else {
			if !exact(wire, "record") {
				t.Fatal(command, wire)
			}
			raw = obj(wire["record"])
		}
		if !exact(raw, "recordId", "operationId", "nativeId", "path", "state", "sha256", "canRollback", "files", "impl", "absenceKind", "retainedKinds", "reasonCode", "blocksImport", "canResolve", "canFinalizeLocal") {
			t.Fatal(command, raw)
		}
		var row recoveryRecord
		if err = json.Unmarshal(encoded(raw), &row); err != nil {
			t.Fatal(err)
		}
		rows = append(rows, row)
	}
	return rows
}

func TestLocalFinalizationRecoveryCLIContract(t *testing.T) {
	allowed := []string{"state.migrationCursor", "queue.revision", "agentMessageBoard.deletedBoard"}
	for _, variant := range []string{"absent", "retained", "invalid-raw-sha", "invalid-operation", "invalid-retained-binding"} {
		t.Run(variant, func(t *testing.T) {
			o, f, ownership := approvalFixture(t)
			run := runPath(o.Home, o.Run)
			// Synthetic historical proof exercises local metadata binding only.
			// It does not claim a live engine/actual8 terminal observation.
			proof := projection(o, "rollback", f.Members, true)
			d := strings.Repeat("d", 64)
			proof["storeObservationDigest"], proof["storeProof"] = d, wireStoreProof(t, d, f.Members)
			retained := variant != "absent"
			if retained {
				obj(array(proof["contexts"])[1])["phase"] = "rollbackRetained"
				for _, v := range array(obj(array(obj(proof["storeProof"])["members"])[0])["relations"]) {
					r := obj(v)
					for _, key := range allowed {
						if text(r["kind"])+"."+text(r["relationClass"]) == key {
							obj(r["counts"])["passive"] = int64(1)
						}
					}
				}
			}
			proof["projectionDigest"], _ = selfDigest(proof, "projectionDigest")
			j := &journal{Version: 4, Impl: "ctxhop-codex", Status: "pending", Phase: "placed", Home: o.Home, Cwd: o.Cwd, ID: f.Members[0].ID, Members: f.Members, ArchiveSHA256: f.ArchiveSHA, EngineSHA256: engineSHA256, NormalEngineSHA256: normalEngineSHA256, LoaderContractID: loaderContractID, ApprovalEvidence: o.ApprovalEvidence, ApprovalOwnership: ownership, TerminalProof: proof}
			if err := saveJournal(run, j, true); err != nil {
				t.Fatal(err)
			}
			oldRemove := finalizationRemoveEntry
			t.Cleanup(func() { finalizationRemoveEntry = oldRemove })
			finalizationRemoveEntry = func(string, string, string, int64, bool) error {
				return fail("injected", "leave durable cleanup pending")
			}
			assertCode(t, beginFinalization(run, j, "rolled_back"), "injected")
			stored, err := loadJournal(o.Home, o.Run)
			if err != nil || stored.Status != "pending" || stored.LocalFinalization == nil || stored.LocalFinalization.State != "cleanup_pending" {
				t.Fatal("internal cleanup state changed", stored, err)
			}
			switch variant {
			case "invalid-raw-sha":
				stored.LocalFinalization.ReceiptSHA256 = strings.Repeat("0", 64)
			case "invalid-operation":
				path := stored.LocalFinalization.ReceiptPath
				b, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				v, err := parseJSON(b)
				if err != nil {
					t.Fatal(err)
				}
				r := obj(v)
				r["operationId"] = strings.Repeat("0", 32)
				r["receiptDigest"], err = selfDigest(r, "receiptDigest")
				if err != nil {
					t.Fatal(err)
				}
				b = encoded(r)
				if err = os.WriteFile(path, b, 0600); err != nil {
					t.Fatal(err)
				}
				stored.LocalFinalization.ReceiptSHA256 = digest(b)
				stored.LocalFinalization.ReceiptDigest = text(r["receiptDigest"])
			case "invalid-retained-binding":
				stored.LocalFinalization.RetainedKinds = allowed[:1]
			}
			if err = saveJournal(run, stored, false); err != nil {
				t.Fatal(err)
			}
			for index, row := range recoveryCLIRows(t, o.Home, o.Run) {
				if strings.HasPrefix(variant, "invalid-") {
					if row.State != "unreadable" || !row.BlocksImport || row.CanRollback || row.CanResolve || row.CanFinalizeLocal || row.ReasonCode == nil || *row.ReasonCode != "finalization_binding_invalid" || row.AbsenceKind != nil || len(row.RetainedKinds) != 0 {
						t.Fatal("invalid bound receipt gained capability", row)
					}
				} else {
					if row.State != "pending" || !row.BlocksImport || row.CanRollback || row.CanResolve || !row.CanFinalizeLocal || row.ReasonCode != nil || row.AbsenceKind == nil {
						t.Fatal("external cleanup pending contract", row)
					}
					wantAbsence, wantKinds := "absent", []string{}
					if retained {
						wantAbsence, wantKinds = "retained", allowed
					}
					if *row.AbsenceKind != wantAbsence || !bytes.Equal(encoded(row.RetainedKinds), encoded(wantKinds)) {
						t.Fatal("historical passive catalog changed", row)
					}
				}
				t.Logf("cleanupContractRow[%s][%d]=%s", variant, index, encoded(row))
			}
		})
	}
}

func TestRecoveryNativeResolveAndChangedSHA(t *testing.T) {
	home, run := t.TempDir(), strings.Repeat("c", 32)
	path := filepath.Join(runPath(home, run), "journal.json")
	raw := []byte("invalid JSON safely preserved")
	if err := createFile(path, raw); err != nil {
		t.Fatal(err)
	}
	row, err := classifyRecoveryRecord(home, run)
	if err != nil || row.State != "unreadable" || !row.CanResolve || row.NativeID == nil || !fileIDRE.MatchString(*row.NativeID) {
		t.Fatal(row, err)
	}
	if _, err = recoveryResolve(home, run, strings.Repeat("0", 64)); err == nil {
		t.Fatal("changed SHA was accepted")
	}
	resolved, err := recoveryResolve(home, run, digest(raw))
	if err != nil || resolved.State != "resolved" || resolved.BlocksImport || *resolved.NativeID != *row.NativeID {
		t.Fatal(resolved, err)
	}
	after, err := os.ReadFile(resolved.Path)
	if err != nil || !bytes.Equal(raw, after) {
		t.Fatal("resolved bytes changed", err)
	}
	if _, err = recoveryResolve(home, run, digest(raw)); err != nil {
		t.Fatal("idempotent native resolve failed", err)
	}
}

func TestRecoveryNativeRenameUTF16Terminator(t *testing.T) {
	for _, terminated := range []bool{false, true} {
		t.Run(fmt.Sprintf("terminated-%v", terminated), func(t *testing.T) {
			home, run := t.TempDir(), strings.Repeat("c", 32)
			if err := createFile(filepath.Join(runPath(home, run), "journal.json"), []byte("raw")); err != nil {
				t.Fatal(err)
			}
			_, lease, err := pinRecoveryRecord(home, run, true)
			if err != nil || lease.File == nil {
				t.Fatal(err)
			}
			defer func() {
				if err := lease.Close(); err != nil {
					t.Fatal(err)
				}
			}()
			name, err := syscall.UTF16FromString(filepath.Join(runPath(home, run), "journal.resolved.json"))
			if err != nil {
				t.Fatal(err)
			}
			type renameInfo struct {
				Replace uint8
				Root    syscall.Handle
				Length  uint32
				Name    uint16
			}
			offset := int(unsafe.Offsetof(renameInfo{}.Name))
			// Poison the backing storage just beyond the advertised unterminated
			// name. It makes the old heap-dependent Win32 failure deterministic.
			buffer := make([]byte, offset+2*(len(name)+1))
			(*renameInfo)(unsafe.Pointer(&buffer[0])).Length = uint32(2 * (len(name) - 1))
			for index, value := range name {
				*(*uint16)(unsafe.Pointer(&buffer[offset+2*index])) = value
			}
			length := offset + 2*len(name)
			if !terminated {
				*(*uint16)(unsafe.Pointer(&buffer[offset+2*(len(name)-1)])) = '*'
				length -= 2
			}
			ok, _, nativeErr := proc("SetFileInformationByHandle").Call(lease.File.Fd(), 3, uintptr(unsafe.Pointer(&buffer[0])), uintptr(length))
			t.Logf("terminated=%v nativeSuccess=%v nativeError=%v", terminated, ok != 0, nativeErr)
			if terminated && ok == 0 || !terminated && ok != 0 {
				t.Fatal("Win32 rename termination contract changed", nativeErr)
			}
		})
	}
}
