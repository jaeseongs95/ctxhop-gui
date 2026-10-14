//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"unsafe"
)

func TestRecoveryDirectoryReaderKeepsMetadataPin(t *testing.T) {
	path := t.TempDir()
	pin, err := snapshotOpen(path, true)
	if err != nil {
		t.Fatal(err)
	}
	defer pin.File.Close()
	if _, err = pin.File.ReadDir(1); err == nil || errors.Is(err, io.EOF) {
		t.Fatal("metadata-only pin unexpectedly enumerated", err)
	}
	entries, err := snapshotDirectoryEntries(pin, 1)
	if err != nil || len(entries) != 0 {
		t.Fatal(entries, err)
	}
	reader, err := snapshotOpenAccess(path, true, 0x81)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Rename(path, path+"-replaced"); err == nil {
		reader.File.Close()
		t.Fatal("directory replacement escaped the LIST_DIRECTORY reader")
	}
	if err = reader.File.Close(); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(path, "unknown"), []byte("x"), 0600); err != nil {
		t.Fatal(err)
	}
	entries, err = snapshotDirectoryEntries(pin, 2)
	if err != nil || len(entries) != 1 || entries[0].Name() != "unknown" {
		t.Fatal(entries, err)
	}
	changed := pin
	changed.Info.FileIndexLow ^= 1
	if _, err = snapshotDirectoryEntries(changed, 1); err == nil {
		t.Fatal("mismatched pin accepted")
	}
	if err = pin.File.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err = snapshotDirectoryEntries(pin, 1); err == nil {
		t.Fatal("closed pin accepted")
	}
}

func TestRecoveryInventoryDirectoriesAndUnknownEntries(t *testing.T) {
	for _, extra := range []string{"", "root", "rollouts"} {
		t.Run(extra, func(t *testing.T) {
			o, f, _ := approvalFixture(t)
			root := filepath.Dir(recoveryPath(o))
			if err := os.MkdirAll(filepath.Join(root, "rollouts"), 0700); err != nil {
				t.Fatal(err)
			}
			manifest := recoveryManifest{1, recoveryProfile, o.Run, o.Home, o.ApprovalEvidence.ManifestSHA256, []recoveryRollout{}}
			b := append(encoded(manifest), '\n')
			if err := createFile(recoveryPath(o), b); err != nil {
				t.Fatal(err)
			}
			o.RecoveryEvidence = &recoveryDescriptor{recoveryProfile, recoveryPath(o), digest(b)}
			if extra != "" {
				path := root
				if extra == "rollouts" {
					path = filepath.Join(path, "rollouts")
				}
				if err := os.WriteFile(filepath.Join(path, "unknown"), []byte("x"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			lease, err := pinRecovery(o, f.Members)
			if extra == "" {
				if err != nil {
					t.Fatal(err)
				}
				if err = lease.Close(); err != nil {
					t.Fatal(err)
				}
			} else if err == nil {
				lease.Close()
				t.Fatal("unknown evidence entry accepted")
			}
		})
	}
}

func TestTerminalDigestTypedAndReloadedValues(t *testing.T) {
	proof := object{"strings": []string{"x"}, "nullable": (*string)(nil), "u64": json.Number("18446744073709551615")}
	first, err := terminalDigest(proof)
	if err != nil {
		t.Fatal(err)
	}
	v, err := parseJSON(encoded(proof))
	if err != nil {
		t.Fatal(err)
	}
	second, err := terminalDigest(obj(v))
	if err != nil || first == nil || second == nil || *first != *second {
		t.Fatal(first, second, err)
	}
}

func TestRecoveryDirectoryReadAndCloseErrors(t *testing.T) {
	for _, variant := range []string{"read", "close"} {
		t.Run(variant, func(t *testing.T) {
			pin, err := snapshotOpen(t.TempDir(), true)
			if err != nil {
				t.Fatal(err)
			}
			defer pin.File.Close()
			old := snapshotDirectoryRead
			defer func() { snapshotDirectoryRead = old }()
			snapshotDirectoryRead = func(reader *os.File, count int) ([]os.DirEntry, error) {
				if variant == "read" {
					return nil, syscall.ERROR_ACCESS_DENIED
				}
				if err := reader.Close(); err != nil {
					t.Fatal(err)
				}
				return nil, io.EOF
			}
			if _, err = snapshotDirectoryEntries(pin, 1); err == nil {
				t.Fatal("read/close failure became success")
			}
		})
	}
}

func TestRecoveryMetadataOnlyAncestorACL(t *testing.T) {
	parent := t.TempDir()
	child := filepath.Join(parent, "child")
	if err := os.Mkdir(child, 0700); err != nil {
		t.Fatal(err)
	}
	sid, sd, err := snapshotSecurity()
	if err != nil {
		t.Fatal(err)
	}
	proc("LocalFree").Call(uintptr(unsafe.Pointer(sd)))
	setACL := func(target, rights string) {
		value, _ := syscall.UTF16PtrFromString("D:P(A;;" + rights + ";;;" + sid + ")")
		var descriptor *byte
		ok, _, err := syscall.NewLazyDLL("advapi32.dll").NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW").Call(uintptr(unsafe.Pointer(value)), 1, uintptr(unsafe.Pointer(&descriptor)), 0)
		if ok == 0 {
			t.Fatal(err)
		}
		defer proc("LocalFree").Call(uintptr(unsafe.Pointer(descriptor)))
		path, _ := syscall.UTF16PtrFromString(target)
		ok, _, err = syscall.NewLazyDLL("advapi32.dll").NewProc("SetFileSecurityW").Call(uintptr(unsafe.Pointer(path)), 0x80000004, uintptr(unsafe.Pointer(descriptor)))
		if ok == 0 {
			t.Fatal(err)
		}
	}
	setACL(child, "FA")
	setACL(parent, "0x1000a0") // SYNCHRONIZE for synchronous CreateFile + metadata/traverse; no LIST_DIRECTORY.
	defer setACL(parent, "FA")
	for _, target := range []string{parent, child} {
		path, _ := syscall.UTF16PtrFromString(target)
		for _, access := range []uint32{0x80, 0xa0, 0x81} {
			h, e := syscall.CreateFile(path, access, 3, nil, syscall.OPEN_EXISTING, 0x02200000, 0)
			t.Logf("native ACL path=%s access=%#x error=%v", target, access, e)
			if e == nil {
				if e = syscall.CloseHandle(h); e != nil {
					t.Fatal(e)
				}
			}
		}
	}
	anchors := &dbAcquisition{}
	if err = anchors.lockDirs(child); err != nil {
		t.Fatalf("metadata-only ancestor was rejected after %d pins: %v", len(anchors.Dirs), err)
	}
	defer func() {
		if err := anchors.releaseLeases(); err != nil {
			t.Fatal(err)
		}
	}()
	if _, err = snapshotDirectoryEntries(anchors.Dirs[len(anchors.Dirs)-1], 1); err != nil {
		t.Fatal("child enumeration escalated ancestor rights", err)
	}
	if _, err = snapshotDirectoryEntries(anchors.Dirs[len(anchors.Dirs)-2], 1); err == nil {
		t.Fatal("LIST_DIRECTORY denial was ignored")
	}
}
