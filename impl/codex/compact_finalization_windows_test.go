//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func pendingReferenceCleanup(t *testing.T) (options, *journal) {
	t.Helper()
	o, f, owner := approvalFixture(t)
	run := runPath(o.Home, o.Run)
	ref := o
	ref.Home, ref.ApprovalEvidence = filepath.Join(run, "ref"), nil
	d, refOwner, err := createApproval(ref, f)
	if err != nil {
		t.Fatal(err)
	}
	j := &journal{Version: 4, Impl: "ctxhop-codex", Status: "pending", Phase: "staged", Home: o.Home, Cwd: o.Cwd, ID: f.Members[0].ID, Members: f.Members, ArchiveSHA256: f.ArchiveSHA, EngineSHA256: engineSHA256, NormalEngineSHA256: normalEngineSHA256, LoaderContractID: loaderContractID, ApprovalEvidence: o.ApprovalEvidence, ApprovalOwnership: owner, ReferenceApprovalEvidence: d, ReferenceApprovalOwnership: refOwner}
	if err = saveJournal(run, j, true); err != nil {
		t.Fatal(err)
	}
	oldSave := finalizationSaveJournal
	finalizationSaveJournal = func(path string, j *journal, initial bool) error {
		if j.LocalFinalization.State == "complete" {
			return fail("injected", "final save")
		}
		return oldSave(path, j, initial)
	}
	err = beginFinalization(run, j, "rolled_back")
	finalizationSaveJournal = oldSave
	assertCode(t, err, "injected")
	if _, err = os.Stat(d.ManifestPath); !os.IsNotExist(err) {
		t.Fatal("nested reference manifest survived", err)
	}
	j, err = loadJournal(o.Home, o.Run)
	if err != nil {
		t.Fatal(err)
	}
	return o, j
}

func TestReferenceCompactSourceLessRestartBindings(t *testing.T) {
	for _, variant := range []string{"valid-stored-pins", "missing", "tamper", "schema", "home", "run", "order", "M", "Q", "mapping", "source-path", "pins"} {
		t.Run(variant, func(t *testing.T) {
			o, j := pendingReferenceCleanup(t)
			path := filepath.Join(runPath(o.Home, o.Run), "reference-approval-manifest.json")
			b, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			v, _ := parseJSON(b)
			m := obj(v)
			member := obj(array(m["members"])[0])
			switch variant {
			case "valid-stored-pins":
				oldEngine, oldNormal, oldLoader := engineSHA256, normalEngineSHA256, loaderContractID
				t.Cleanup(func() { engineSHA256, normalEngineSHA256, loaderContractID = oldEngine, oldNormal, oldLoader })
				engineSHA256, normalEngineSHA256, loaderContractID = strings.Repeat("c", 64), strings.Repeat("d", 64), "ctxhop-prestart-v2:new"
			case "missing":
				err = os.Remove(path)
			case "tamper":
				err = os.WriteFile(path, append(b, ' '), 0600)
			case "schema":
				m["schemaVersion"] = num(2)
			case "home":
				m["home"] = o.Home
			case "run":
				m["operationId"] = strings.Repeat("0", 32)
			case "order":
				a := array(m["members"])
				a[0], a[1] = a[1], a[0]
			case "M":
				member["id"] = "44444444-4444-4444-8444-444444444444"
			case "Q":
				member["sessionId"] = "44444444-4444-4444-8444-444444444444"
			case "mapping":
				member["role"] = "child"
			case "source-path":
				obj(member["source"])["path"] = filepath.Join(o.Home, "foreign")
			case "pins":
				obj(m["pins"])["engineSha256"] = strings.Repeat("c", 64)
			}
			if err != nil {
				t.Fatal(err)
			}
			if variant != "valid-stored-pins" && variant != "missing" && variant != "tamper" {
				b = encoded(m)
				if err = os.WriteFile(path, b, 0600); err != nil {
					t.Fatal(err)
				}
				// Re-sign the descriptor too: semantic validation must still reject.
				j.ReferenceApprovalEvidence.ManifestSHA256 = digest(b)
				if err = saveJournal(runPath(o.Home, o.Run), j, false); err != nil {
					t.Fatal(err)
				}
			}
			result, err := finalizeLocal(o.Home, o.Run)
			if variant == "valid-stored-pins" {
				if err != nil || result["status"] != "rolled_back" {
					t.Fatal(result, err)
				}
			} else if err == nil {
				t.Fatal("invalid preserved reference accepted", variant)
			}
		})
	}
}
