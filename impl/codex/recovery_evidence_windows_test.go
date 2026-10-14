//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func recoveryRawFixture(t *testing.T) (options, *family, recoveryRollout, []byte) {
	t.Helper()
	o, f, _ := approvalFixture(t)
	m := f.Members[0]
	rid := "44444444-4444-4444-8444-444444444444"
	origin := strings.Replace(m.OriginBasename, m.ImmutableRolloutIDs[0], rid, 1) + ".zst"
	path := filepath.Join(o.Home, "sessions", origin)
	// Deliberately opaque to Go. This fixture proves raw preservation, never
	// canonical/zstd validity or a Rust full-source witness.
	raw := []byte{0x28, 0xb5, 0x2f, 0xfd, 0, 1, 2, 3, 0xff, '\n'}
	if err := createFile(path, raw); err != nil {
		t.Fatal(err)
	}
	rollout := recoveryRollout{m.ID, m.SessionID, rid, origin, m.Parent, object{"thread_id": "55555555-5555-4555-8555-555555555555", "end_ordinal_exclusive": json.Number("18446744073709551615"), "end_byte_offset": json.Number("9223372036854775808")}, approvalSource{path, int64(len(raw)), digest(raw)}}
	return o, f, rollout, raw
}

func TestRecoveryOpaqueCopyAndFactBoundaries(t *testing.T) {
	o, f, rollout, raw := recoveryRawFixture(t)
	value := array(cloneJSON([]recoveryRollout{rollout}))
	facts, err := recoveryRollouts(value, o, f.Members, false)
	if err != nil || len(facts) != 1 || facts[0].ImmutableRolloutID == facts[0].ID {
		t.Fatal(facts, err)
	}
	for _, variant := range []string{"u64-overflow", "negative", "duplicate-R", "original-R", "wrong-Q", "foreign-path"} {
		t.Run(variant, func(t *testing.T) {
			v := array(cloneJSON(value))
			r := obj(v[0])
			switch variant {
			case "u64-overflow":
				obj(r["historyBase"])["end_byte_offset"] = json.Number("18446744073709551616")
			case "negative":
				obj(r["historyBase"])["end_ordinal_exclusive"] = json.Number("-1")
			case "duplicate-R":
				v = append(v, cloneJSON(r))
			case "original-R":
				r["immutableRolloutId"] = f.Members[0].ImmutableRolloutIDs[0]
			case "wrong-Q":
				r["sessionId"] = "66666666-6666-4666-8666-666666666666"
			case "foreign-path":
				obj(r["source"])["path"] = filepath.Join(t.TempDir(), rollout.OriginBasename)
			}
			if _, err := recoveryRollouts(v, o, f.Members, false); err == nil {
				t.Fatal("unsafe fact accepted", variant)
			}
		})
	}
	descriptor, err := persistRecovery(o, f.Members, facts)
	if err != nil {
		t.Fatal(err)
	}
	o.RecoveryEvidence = descriptor
	lease, err := pinRecovery(o, f.Members)
	if err != nil {
		t.Fatal(err)
	}
	copyPath := lease.Manifest.Rollouts[0].Source.Path
	if filepath.Base(copyPath) != "000000.jsonl.zst" || lease.Manifest.Rollouts[0].OriginBasename != rollout.OriginBasename {
		t.Fatal(lease.Manifest)
	}
	if err = lease.Close(); err != nil {
		t.Fatal(err)
	}
	copyBytes, err := os.ReadFile(copyPath)
	if err != nil || !bytes.Equal(copyBytes, raw) {
		t.Fatal("opaque source was transformed", err)
	}
	if _, err = persistRecovery(o, f.Members, facts); err != nil {
		t.Fatal("exact existing inventory retry failed", err)
	}
	facts[0].Source.SHA256 = strings.Repeat("0", 64)
	if _, err = persistRecovery(o, f.Members, facts); err == nil {
		t.Fatal("existing evidence was silently resealed")
	}
}

func recoveryFactResponse(t *testing.T, s *session, rollouts []recoveryRollout) object {
	t.Helper()
	r := obj(cloneJSON(object{"phase": "recoveryPlan", "inputComplete": false, "binding": s.Binding, "plan": object{"schemaVersion": 1, "profile": recoveryPlanProfile, "operationId": s.Options.Run, "home": s.Options.Home, "approvalManifestSha256": s.Options.ApprovalEvidence.ManifestSHA256, "rollouts": rollouts, "planDigest": strings.Repeat("a", 64)}}))
	delete(obj(r["plan"]), "planDigest")
	b, err := storeCanonicalJSON(r)
	if err != nil {
		t.Fatal(err)
	}
	obj(r["plan"])["planDigest"] = digest(b)
	return r
}

func TestRecoveryDiscoveryAbortOnlyAndFreshSecondOrdering(t *testing.T) {
	for _, closeFails := range []bool{false, true} {
		t.Run(map[bool]string{false: "fresh-second", true: "first-close-fails"}[closeFails], func(t *testing.T) {
			o, f, rollout, _ := recoveryRawFixture(t)
			j := &journal{Version: 4, Impl: "ctxhop-codex", Status: "pending", Phase: "placed", Home: o.Home, Cwd: o.Cwd, ID: f.Members[0].ID, Members: f.Members, ArchiveSHA256: f.ArchiveSHA, EngineSHA256: engineSHA256, NormalEngineSHA256: normalEngineSHA256, LoaderContractID: loaderContractID, ApprovalEvidence: o.ApprovalEvidence}
			approval, err := pinApproval(o, f.Members)
			if err != nil {
				t.Fatal(err)
			}
			j.ApprovalOwnership = &approval.Ownership
			if err = approval.Close(); err != nil {
				t.Fatal(err)
			}
			if err := saveJournal(runPath(o.Home, o.Run), j, true); err != nil {
				t.Fatal(err)
			}
			oldPrepare := prepareEngine
			defer func() { prepareEngine = oldPrepare }()
			started, closed := 0, false
			prepareEngine = func(next options, operation string, members []member) (*session, error) {
				started++
				s, err := oldPrepare(next, operation, members)
				if err != nil {
					return nil, err
				}
				if started == 1 {
					s.Call = func(method string, params object) (object, error) {
						if method == "ctxhop/recovery-plan" {
							return recoveryFactResponse(t, s, []recoveryRollout{rollout}), nil
						}
						if method == "ctxhop/abort" {
							return object{}, nil
						}
						t.Fatal("discovery sent application/proof method", method)
						return nil, nil
					}
					oldClose := s.Close
					s.Close = func() error {
						if !s.DiscoveryIssued {
							t.Fatal("first process closed before discovery")
						}
						if _, err := s.Call("ctxhop/complete", s.Binding); err == nil {
							t.Fatal("discovery process allowed complete")
						}
						stored, err := loadJournal(o.Home, o.Run)
						if err != nil || stored.RecoveryEvidence == nil {
							t.Fatal("first process closed before durable journal binding", err)
						}
						closed = true
						if err = oldClose(); err != nil {
							return err
						}
						if closeFails {
							return fail("injected", "first process close failed")
						}
						return nil
					}
				} else {
					if !closed || next.RecoveryEvidence == nil || started != 2 {
						t.Fatal("fresh second ordering/cycle failed")
					}
					if s.DiscoveryIssued {
						t.Fatal("fresh second reused discovery state")
					}
				}
				return s, nil
			}
			second, recovered, err := prepareRecoveryEngine(o, j, f.Members)
			if closeFails {
				if err == nil || second != nil || started != 1 {
					t.Fatal("close failure allowed fresh second", started, err)
				}
			} else {
				if err != nil || second == nil || recovered.RecoveryEvidence == nil || started != 2 {
					t.Fatal(started, err)
				}
				if err = second.Close(); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}
