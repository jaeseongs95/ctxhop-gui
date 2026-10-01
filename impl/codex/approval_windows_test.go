//go:build windows

package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixtureApproval(t *testing.T, o options, f *family) options {
	t.Helper()
	oldEngine, oldNormal := engineSHA256, normalEngineSHA256
	if engineSHA256 == "" {
		engineSHA256 = strings.Repeat("a", 64)
	}
	if normalEngineSHA256 == "" {
		normalEngineSHA256 = strings.Repeat("b", 64)
	}
	t.Cleanup(func() { engineSHA256, normalEngineSHA256 = oldEngine, oldNormal })
	if o.Run == "" {
		o.Run = nonce()
	}
	if f.ArchiveSHA == "" {
		f.ArchiveSHA = digest(archiveBytes(f, 2, nil))
	}
	if e := support(f, o.Home); e != nil {
		t.Fatal(e)
	}
	d, _, e := createApproval(o, f)
	if e != nil {
		t.Fatal(e)
	}
	o.ApprovalEvidence = d
	return o
}
func approvalFixture(t *testing.T) (options, *family, *approvalOwnership) {
	t.Helper()
	f := fixtureFamily("legacy")
	o := options{Home: t.TempDir(), Cwd: t.TempDir()}
	o.Archive = writeArchiveFixture(t, f, 2, nil)
	var e error
	f, e = readArchive(o.Archive)
	if e != nil {
		t.Fatal(e)
	}
	installMock(t, f)
	o = fixtureApproval(t, o, f)
	l, e := pinApproval(o, f.Members)
	if e != nil {
		t.Fatal(e)
	}
	ownership := l.Ownership
	if e = l.Close(); e != nil {
		t.Fatal(e)
	}
	return o, f, &ownership
}
func TestApprovalWholeSourceLifetimeAndScope(t *testing.T) {
	o, f, ownership := approvalFixture(t)
	for i, m := range f.Members {
		if e := createFile(filepath.Join(runPath(o.Home, o.Run), "stage", fmt.Sprintf("%04d.jsonl", i)), m.Raw); e != nil {
			t.Fatal(e)
		}
	}
	if e := os.RemoveAll(filepath.Join(runPath(o.Home, o.Run), "stage")); e != nil {
		t.Fatal(e)
	}
	l, e := pinApproval(o, f.Members)
	if e != nil {
		t.Fatal("approval lost with stage", e)
	}
	original := encoded(l.Manifest)
	before := l.MappingDigest
	if e = l.Close(); e != nil {
		t.Fatal(e)
	}
	if e := os.Remove(o.Archive); e != nil {
		t.Fatal(e)
	}
	current := append([]member(nil), f.Members...)
	current[0].Path = filepath.Join(o.Home, "absent-current.jsonl")
	current[0].SHA256 = strings.Repeat("b", 64)
	l, e = pinApproval(o, current)
	if e != nil || l.MappingDigest != before || !bytes.Equal(original, encoded(l.Manifest)) {
		t.Fatal("actual path overwrote immutable source", e)
	}
	l.Close()
	ref := o
	ref.Home = filepath.Join(runPath(o.Home, o.Run), "ref")
	ref.ApprovalEvidence = o.ApprovalEvidence
	if _, e = pinApproval(ref, f.Members); e == nil {
		t.Fatal("parent scope reused in ref home")
	}
	if e = cleanupApproval(o, f.Members, ownership); e != nil {
		t.Fatal(e)
	}
	if _, e = os.Stat(filepath.Dir(o.ApprovalEvidence.ManifestPath)); !os.IsNotExist(e) {
		t.Fatal("approval not removed", e)
	}
}
func TestApprovalRejectsForgedSourceAndIdentity(t *testing.T) {
	for _, kind := range []string{"Q", "R", "slot", "basename", "size", "hash", "scope", "duplicate", "hardlink", "partial", "identity", "extra"} {
		t.Run(kind, func(t *testing.T) {
			o, f, ownership := approvalFixture(t)
			path := o.ApprovalEvidence.ManifestPath
			raw, e := os.ReadFile(path)
			if e != nil {
				t.Fatal(e)
			}
			v, e := parseJSON(raw)
			if e != nil {
				t.Fatal(e)
			}
			m := obj(v)
			first := obj(array(m["members"])[0])
			source := obj(first["source"])
			switch kind {
			case "Q":
				first["sessionId"] = otherID
			case "R":
				first["immutableRolloutIds"] = []any{otherID}
			case "slot":
				source["path"] = filepath.Join(filepath.Dir(path), "members", "0001.jsonl")
			case "basename":
				first["originBasename"] = "0000.jsonl"
			case "size":
				source["size"] = num(1)
			case "hash":
				source["sha256"] = strings.Repeat("b", 64)
			case "scope":
				m["home"] = t.TempDir()
			case "duplicate":
				raw = []byte(`{"schemaVersion":1,"schemaVersion":1}`)
			case "extra":
				m["unknown"] = true
			case "hardlink":
				if e = os.Link(text(source["path"]), filepath.Join(t.TempDir(), "alias.jsonl")); e != nil {
					t.Fatal(e)
				}
			case "identity":
				ownership.ManifestIdentity = strings.Repeat("0", 24)
				if e = cleanupApproval(o, f.Members, ownership); e == nil {
					t.Fatal("forged cleanup identity accepted")
				}
				return
			case "partial":
				p := text(source["path"])
				b, e := os.ReadFile(p)
				if e != nil {
					t.Fatal(e)
				}
				b = b[:len(b)-1]
				if e = os.WriteFile(p, b, 0600); e != nil {
					t.Fatal(e)
				}
				source["size"] = len(b)
				source["sha256"] = digest(b)
			}
			if kind != "hardlink" {
				if kind != "duplicate" {
					raw = append(encoded(m), '\n')
				}
				if e = os.WriteFile(path, raw, 0600); e != nil {
					t.Fatal(e)
				}
				o.ApprovalEvidence.ManifestSHA256 = digest(raw)
			}
			l, e := pinApproval(o, f.Members)
			if e == nil {
				l.Close()
				t.Fatal("forged source accepted", kind)
			}
		})
	}
}
func TestApprovalCanonicalQAndStableToken(t *testing.T) {
	o, f, _ := approvalFixture(t)
	p := projection(o, "plan", nil, true)
	a := tokenFor(o, f, p)
	q := obj(clone(p))
	q["generation"] = num(99)
	q["acquisitionId"] = nonce()
	q["approvalEvidenceDigest"] = strings.Repeat("c", 64)
	q["approvedMappingDigest"] = strings.Repeat("d", 64)
	if tokenFor(o, f, q) != a {
		t.Fatal("ephemeral approval/process state in token")
	}
	f.Members[1].SessionID = childID
	if tokenFor(o, f, p) == a {
		t.Fatal("Q omitted from token")
	}
	for _, value := range []any{nil, "", true, num(1), otherID} {
		header := obj(clone(f.Members[1].Header))
		header["session_id"] = value
		if value == otherID {
			if _, e := records(append(encoded(object{"type": "session_meta", "payload": header}), '\n'), childID, []string{rootID}); e == nil {
				t.Fatal("foreign Q accepted")
			}
		} else if _, e := canonicalRolloutSessionID(header); e == nil {
			t.Fatal("invalid present Q")
		}
	}
	header := obj(clone(f.Members[1].Header))
	delete(header, "session_id")
	if q, e := canonicalRolloutSessionID(header); e != nil || q != childID {
		t.Fatal("missing child Q normalized to parent", q, e)
	}
}
func TestApprovalWireAndFrameBounds(t *testing.T) {
	o, f, _ := approvalFixture(t)
	descriptors := []any{object{"id": rootID, "parentId": nil, "role": "root", "rolloutPath": nil, "rolloutSha256": nil}}
	r, e := prepareRequest(o, "rollback", "n", descriptors)
	if e != nil || len(r) != 8 {
		t.Fatal("prepare exact8", e)
	}
	missing := o
	missing.ApprovalEvidence = nil
	if _, e = prepareRequest(missing, "rollback", "n", descriptors); e == nil {
		t.Fatal("member prepare without evidence")
	}
	r, e = prepareRequest(missing, "plan", "n", []any{})
	if e != nil || r["approvalEvidence"] != nil {
		t.Fatal("plan nullable descriptor", e)
	}
	p := projection(o, "import", f.Members, true)
	if e = validateApprovalProjection(p, o, f.Members, true); e != nil {
		t.Fatal(e)
	}
	for _, key := range []string{"mappingProfile", "approvalEvidenceDigest", "approvedMappingDigest"} {
		q := obj(clone(p))
		q[key] = nil
		if e = validateApprovalProjection(q, o, f.Members, true); e == nil {
			t.Fatal("missing mapping binding", key)
		}
	}
	for _, size := range []int{(1 << 20) + 1, lineLimit, lineLimit + 1} {
		raw := bytes.Repeat([]byte{'x'}, size)
		line, e := streamLine(bufio.NewReader(bytes.NewReader(append(raw, '\n'))))
		if size <= lineLimit && (e != nil || len(line) != size) || size > lineLimit && e == nil {
			t.Fatal("incoming bound", size, e)
		}
	}
	if _, e = streamLine(bufio.NewReader(strings.NewReader(`{"id":1}`))); e != io.ErrUnexpectedEOF {
		t.Fatal("partial EOF accepted", e)
	}
	base := len(encoded(object{"x": ""}))
	for _, size := range []int{lineLimit, lineLimit + 1} {
		b, e := rpcFrame(object{"x": strings.Repeat("x", size-base)})
		if size == lineLimit && (e != nil || len(b) != size+1) || size > lineLimit && e == nil {
			t.Fatal("outgoing bound", size, e)
		}
	}
	t.Setenv("CTXHOP_S4_SCHEMA_CANCEL_POINT", "afterReaders")
	t.Setenv("CTXHOP_R45_SECRET", "do-not-forward")
	env, e := processEnv(o.Home)
	if e != nil {
		t.Fatal(e)
	}
	for _, entry := range env {
		if strings.HasPrefix(strings.ToUpper(entry), "CTXHOP_") {
			t.Fatal("parent test environment leak")
		}
	}
	l, e := pinApproval(o, f.Members)
	if e != nil {
		t.Fatal(e)
	}
	_, _, e = approvalHash(l.Files[0].File, 4<<20, time.Now().Add(-time.Second))
	if e == nil {
		t.Fatal("expired scan accepted")
	}
	l.Close()
}

func TestApprovalResourceAndJournalBounds(t *testing.T) {
	o, f, ownership := approvalFixture(t)
	root := filepath.Dir(o.ApprovalEvidence.ManifestPath)
	m := approvalManifest{1, approvalProfile, f.ArchiveSHA, 2, o.Run, o.Home, o.Cwd, approvalPins{engineSHA256, normalEngineSHA256, loaderContractID}, familyApprovalMembers(f, root)}
	raw := encoded(m)
	for _, size := range []int{4 << 20, (4 << 20) + 1} {
		padded := append(append([]byte(nil), raw...), bytes.Repeat([]byte{' '}, size-len(raw))...)
		_, e := validateApprovalManifest(padded, o, f.Members)
		if size == 4<<20 && e != nil || size > 4<<20 && e == nil {
			t.Fatal("manifest UTF-8 serialized limit", size, e)
		}
	}
	ms := make([]member, 2001)
	for i := range ms {
		ms[i] = f.Members[0]
		if i > 0 {
			ms[i].ID = fmt.Sprintf("%08x-1111-4111-8111-%012x", i, i)
			ms[i].Parent = &ms[0].ID
		}
		ms[i].ImmutableRolloutIDs = []string{ms[i].ID}
		ms[i].SessionID = ms[i].ID
		ms[i].ArchiveEntry = fmt.Sprintf("rollouts/%04d.jsonl", i)
		ms[i].OriginBasename = "rollout-2026-10-01T00-00-00-" + ms[i].ID + ".jsonl"
	}
	for _, count := range []int{2000, 2001} {
		large := &family{Members: ms[:count]}
		m.Members = familyApprovalMembers(large, root)
		_, e := validateApprovalManifest(encoded(m), o, large.Members)
		if count == 2000 && e != nil || count == 2001 && e == nil {
			t.Fatal("member count bound", count, e)
		}
	}
	budget := append([]member(nil), f.Members...)
	budget[0].Size = limit / 2
	budget[1].Size = limit/2 + 1
	m.Members = familyApprovalMembers(&family{Members: budget}, root)
	if _, e := validateApprovalManifest(encoded(m), o, budget); e == nil {
		t.Fatal("aggregate original source budget accepted")
	}
	j := &journal{Version: 4, Impl: "ctxhop-codex", Status: "pending", Phase: "staged", Home: o.Home, Cwd: o.Cwd, ID: rootID, Members: f.Members, ArchiveSHA256: f.ArchiveSHA, ApprovalEvidence: o.ApprovalEvidence, ApprovalOwnership: ownership}
	run := runPath(o.Home, o.Run)
	if e := saveJournal(run, j, true); e != nil {
		t.Fatal(e)
	}
	if _, e := loadJournal(o.Home, o.Run); e != nil {
		t.Fatal(e)
	}
	j.LastError = "x"
	base := len(encoded(j))
	j.LastError = strings.Repeat("x", (4<<20)-base)
	if e := saveJournal(run, j, false); e != nil {
		t.Fatal("exact journal budget", e)
	}
	j.LastError += "x"
	if e := saveJournal(run, j, false); e == nil {
		t.Fatal("oversize journal accepted")
	}
}

func TestApprovalRejectsChangedCanonicalHeaderAndReparse(t *testing.T) {
	for _, kind := range []string{"root-parent", "copied-header", "copied-header-invalid", "member-junction"} {
		t.Run(kind, func(t *testing.T) {
			o, f, _ := approvalFixture(t)
			root := filepath.Dir(o.ApprovalEvidence.ManifestPath)
			if kind == "member-junction" {
				members := filepath.Join(root, "members")
				target := filepath.Join(root, "original-members")
				if e := os.Rename(members, target); e != nil {
					t.Fatal(e)
				}
				if e := os.Symlink(target, members); e != nil {
					system, e := systemDirectory()
					if e != nil {
						t.Fatal(e)
					}
					if e = makeJunction(system, members, target); e != nil {
						t.Fatal(e)
					}
				}
			} else {
				raw := append([]byte(nil), f.Members[0].Raw...)
				end := bytes.IndexByte(raw, '\n')
				if strings.HasPrefix(kind, "copied-header") {
					v, e := parseJSON(raw[:end])
					if e != nil {
						t.Fatal(e)
					}
					header := obj(obj(v)["payload"])
					header["id"] = otherID
					header["session_id"] = childID
					header["parent_thread_id"] = rootID
					if kind == "copied-header-invalid" {
						header["session_id"] = nil
					}
					raw = append(raw, append(encoded(v), '\n')...)
				} else {
					v, e := parseJSON(raw[:end])
					if e != nil {
						t.Fatal(e)
					}
					obj(obj(v)["payload"])["parent_thread_id"] = otherID
					raw = append(append(encoded(v), '\n'), raw[end+1:]...)
				}
				f.Members[0].Size = int64(len(raw))
				m := approvalManifest{1, approvalProfile, f.ArchiveSHA, 2, o.Run, o.Home, o.Cwd, approvalPins{engineSHA256, normalEngineSHA256, loaderContractID}, familyApprovalMembers(f, root)}
				m.Members[0].Source.SHA256 = digest(raw)
				if e := os.WriteFile(m.Members[0].Source.Path, raw, 0600); e != nil {
					t.Fatal(e)
				}
				manifest := append(encoded(m), '\n')
				if e := os.WriteFile(o.ApprovalEvidence.ManifestPath, manifest, 0600); e != nil {
					t.Fatal(e)
				}
				o.ApprovalEvidence.ManifestSHA256 = digest(manifest)
			}
			l, e := pinApproval(o, f.Members)
			if kind == "copied-header" {
				if e != nil {
					t.Fatal("canonical copied fork metadata rejected", e)
				}
				if l.Manifest.Members[0].ID != rootID || l.Manifest.Members[0].SessionID != rootID || l.Manifest.Members[0].ParentID != nil || l.Manifest.Members[0].ImmutableRolloutIDs[0] != rootID {
					t.Fatal("later metadata promoted to owner")
				}
				if e = l.Close(); e != nil {
					t.Fatal(e)
				}
				return
			}
			if e == nil {
				l.Close()
				t.Fatal("changed canonical source accepted", kind)
			}
		})
	}
}

func TestApprovalV3RollbackKeepsLegacyBoundaries(t *testing.T) {
	for _, phase := range []string{"staged", "placing", "placing-pin-changed"} {
		t.Run(phase, func(t *testing.T) {
			f := fixtureFamily("legacy")
			m := installMock(t, f)
			o := options{Home: t.TempDir(), Cwd: t.TempDir(), Run: nonce()}
			if e := support(f, o.Home); e != nil {
				t.Fatal(e)
			}
			p := phase
			if p == "placing-pin-changed" {
				p = "placing"
			}
			j := &journal{Version: 3, Impl: "ctxhop-codex", Status: "pending", Phase: p, Home: o.Home, Cwd: o.Cwd, ID: rootID, Members: f.Members, ArchiveSHA256: strings.Repeat("a", 64), EngineSHA256: engineSHA256, NormalEngineSHA256: normalEngineSHA256, LoaderContractID: loaderContractID}
			if phase == "placing-pin-changed" {
				j.NormalEngineSHA256 = strings.Repeat("c", 64)
			}
			run := runPath(o.Home, o.Run)
			if e := saveJournal(run, j, true); e != nil {
				t.Fatal(e)
			}
			before, e := os.ReadFile(filepath.Join(run, "journal.json"))
			if e != nil {
				t.Fatal(e)
			}
			r, e := rollback(o)
			if phase == "staged" {
				if e != nil || r["status"] != "rolled_back" {
					t.Fatal(r, e)
				}
				r, e = rollback(o)
				if e != nil || r["status"] != "rolled_back" {
					t.Fatal("legacy idempotence", r, e)
				}
			} else {
				code := "approval_evidence"
				if phase == "placing-pin-changed" {
					code = "engine_untrusted"
				}
				assertCode(t, e, code)
				after, e := os.ReadFile(filepath.Join(run, "journal.json"))
				if e != nil || !bytes.Equal(before, after) {
					t.Fatal("v3 rewritten or upgraded", e)
				}
			}
			if m.Deletes != 0 || m.Active {
				t.Fatal("legacy rollback activated/deleted without approval")
			}
		})
	}
}
