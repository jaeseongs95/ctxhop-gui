//go:build windows

package main

import (
	"bufio"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"unsafe"
)

func nativeCloseFixture(t *testing.T, variant string) (*process, syscall.Handle) {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	p, err := startProcess(exe, t.TempDir(), []string{"CTXHOP_OWNED_JOB_FIXTURE=exit"})
	if err != nil {
		t.Fatal(err)
	}
	line, err := streamLine(bufio.NewReader(p.Out))
	if err != nil || string(line) != "fixture-ready" {
		t.Fatal(line, err)
	}
	var h syscall.Handle
	switch variant {
	case "stdin":
		h = syscall.Handle(p.In.Fd())
	case "stdout":
		h = syscall.Handle(p.Out.Fd())
	case "stderr":
		h = syscall.Handle(p.Err.Fd())
	case "process":
		h = p.handle
	case "job":
		h = p.job
	case "image":
		path := filepath.Join(t.TempDir(), "owned-image-lock.bin")
		if err = createFile(path, []byte("fixture")); err != nil {
			t.Fatal(err)
		}
		p.ImageLocks, err = lockImage(path)
		if err != nil {
			t.Fatal(err)
		}
		h = syscall.Handle(p.ImageLocks[0].Fd())
	default:
		t.Fatal(variant)
	}
	// A real Win32 handle close failure, not an error after a successful close.
	if err = syscall.SetHandleInformation(h, 2, 2); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if p.closed {
			return
		}
		if err := syscall.SetHandleInformation(h, 2, 0); err != nil {
			t.Error(err)
		}
		if err := p.close(); err != nil {
			t.Error("native retry", err)
		}
	})
	return p, h
}

func TestNativeProcessCloseFaultOwnershipAndRetry(t *testing.T) {
	for _, variant := range []string{"stdin", "stdout", "stderr", "process", "job", "image"} {
		t.Run(variant, func(t *testing.T) {
			p, h := nativeCloseFixture(t, variant)
			err := p.close()
			if err == nil || p.closed || !p.jobDrained {
				t.Fatal("native close failure hidden", err, p.closed, p.jobDrained)
			}
			var flags uint32
			ok, _, nativeErr := proc("GetHandleInformation").Call(uintptr(h), uintptr(unsafe.Pointer(&flags)))
			if ok == 0 || flags&2 == 0 {
				t.Fatal("failed native handle lost ownership", nativeErr, flags)
			}
			t.Logf("native close rejected %s; owned protected handle remains; closed=false", variant)
			if err = syscall.SetHandleInformation(h, 2, 0); err != nil {
				t.Fatal(err)
			}
			if err = p.close(); err != nil || !p.closed {
				t.Fatal("explicit retry failed", err)
			}
		})
	}
}

func TestNativeCloseFailureBlocksFreshRecoveryAndReceipt(t *testing.T) {
	for _, variant := range []string{"stdin", "stdout", "stderr", "process", "job", "image"} {
		t.Run(variant, func(t *testing.T) {
			o, f, rollout, _ := recoveryRawFixture(t)
			j := &journal{Version: 4, Impl: "ctxhop-codex", Status: "pending", Phase: "placed", Home: o.Home, Cwd: o.Cwd, ID: f.Members[0].ID, Members: f.Members, ArchiveSHA256: f.ArchiveSHA, EngineSHA256: engineSHA256, NormalEngineSHA256: normalEngineSHA256, LoaderContractID: loaderContractID, ApprovalEvidence: o.ApprovalEvidence}
			lease, err := pinApproval(o, f.Members)
			if err != nil {
				t.Fatal(err)
			}
			j.ApprovalOwnership = &lease.Ownership
			if err = lease.Close(); err != nil {
				t.Fatal(err)
			}
			if err = saveJournal(runPath(o.Home, o.Run), j, true); err != nil {
				t.Fatal(err)
			}
			p, h := nativeCloseFixture(t, variant)
			old := prepareEngine
			t.Cleanup(func() { prepareEngine = old })
			started := 0
			prepareEngine = func(next options, op string, ms []member) (*session, error) {
				started++
				if started > 1 {
					t.Fatal("native close failure allowed fresh second")
				}
				s, err := old(next, op, ms)
				if err != nil {
					return nil, err
				}
				s.P = p
				s.Close = p.close
				s.Call = func(method string, params object) (object, error) {
					if method == "ctxhop/recovery-plan" {
						return recoveryFactResponse(t, s, []recoveryRollout{rollout}), nil
					}
					if method == "ctxhop/abort" {
						return object{}, nil
					}
					t.Fatal(method)
					return nil, nil
				}
				return s, nil
			}
			second, _, err := prepareRecoveryEngine(o, j, f.Members)
			if err == nil || second != nil || started != 1 || p.closed {
				t.Fatal("native failure crossed recovery barrier", err, started)
			}
			if _, err = os.Stat(filepath.Join(runPath(o.Home, o.Run), "local-finalization.json")); !os.IsNotExist(err) {
				t.Fatal("receipt created after native close failure", err)
			}
			if _, err = os.Stat(filepath.Join(runPath(o.Home, o.Run), "approval", "members", "0000.jsonl")); err != nil {
				t.Fatal("evidence cleaned after close failure", err)
			}
			if err = syscall.SetHandleInformation(h, 2, 0); err != nil {
				t.Fatal(err)
			}
			if err = p.close(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestNativeCloseFailureBlocksTerminalReceipt(t *testing.T) {
	for _, variant := range []string{"stdin", "stdout", "stderr", "process", "job", "image"} {
		t.Run(variant, func(t *testing.T) {
			o, _ := importFixture(t, "legacy", false)
			p, h := nativeCloseFixture(t, variant)
			old := prepareEngine
			t.Cleanup(func() { prepareEngine = old })
			prepareEngine = func(next options, op string, ms []member) (*session, error) {
				s, err := old(next, op, ms)
				if err != nil {
					return nil, err
				}
				if op == "cold" {
					oldClose := s.Close
					s.Close = func() error {
						if err := p.close(); err != nil {
							return err
						}
						return oldClose()
					}
				}
				return s, nil
			}
			result, err := importArchive(o)
			if err == nil || result["status"] != "pending" || p.closed {
				t.Fatal("native close failure permitted terminal success", result, err)
			}
			if _, err = os.Stat(filepath.Join(runPath(o.Home, o.Run), "local-finalization.json")); !os.IsNotExist(err) {
				t.Fatal("native close failure created receipt", err)
			}
			if _, err = os.Stat(filepath.Join(runPath(o.Home, o.Run), "approval", "members", "0000.jsonl")); err != nil {
				t.Fatal("native close failure cleaned source", err)
			}
			if err = syscall.SetHandleInformation(h, 2, 0); err != nil {
				t.Fatal(err)
			}
			if err = p.close(); err != nil {
				t.Fatal(err)
			}
		})
	}
}
