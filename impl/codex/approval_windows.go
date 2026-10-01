//go:build windows

package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"
)

const approvalProfile = "ctxhop-approval-member-v1"

type approvalDescriptor struct {
	Profile        string `json:"profile"`
	ManifestPath   string `json:"manifestPath"`
	ManifestSHA256 string `json:"manifestSha256"`
}
type approvalSource struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}
type approvalMember struct {
	ID                  string         `json:"id"`
	ParentID            *string        `json:"parentId"`
	Role                string         `json:"role"`
	ImmutableRolloutIDs []string       `json:"immutableRolloutIds"`
	SessionID           string         `json:"sessionId"`
	ArchiveEntry        string         `json:"archiveEntry"`
	OriginBasename      string         `json:"originBasename"`
	Source              approvalSource `json:"source"`
}
type approvalPins struct {
	EngineSHA256       string `json:"engineSha256"`
	NormalEngineSHA256 string `json:"normalEngineSha256"`
	LoaderContractID   string `json:"loaderContractId"`
}
type approvalManifest struct {
	SchemaVersion int              `json:"schemaVersion"`
	Profile       string           `json:"profile"`
	ArchiveSHA256 string           `json:"archiveSha256"`
	ArchiveFormat int64            `json:"archiveFormat"`
	OperationID   string           `json:"operationId"`
	Home          string           `json:"home"`
	Cwd           string           `json:"cwd"`
	Pins          approvalPins     `json:"pins"`
	Members       []approvalMember `json:"members"`
}

// Persist native identities separately from the immutable wire manifest.
type approvalOwnership struct {
	DirectoryIdentity       string   `json:"directoryIdentity"`
	MemberDirectoryIdentity string   `json:"memberDirectoryIdentity"`
	ManifestIdentity        string   `json:"manifestIdentity"`
	MemberIdentities        []string `json:"memberIdentities"`
}
type approvalLease struct {
	Manifest      approvalManifest
	Ownership     approvalOwnership
	Dirs          []snapshotEntry
	Files         []snapshotEntry
	MappingDigest string
}

func approvalPath(o options) string {
	return filepath.Join(runPath(o.Home, o.Run), "approval", "manifest.json")
}
func memberRole(m member) string {
	if m.Parent != nil {
		return "child"
	}
	return "root"
}
func sameParent(a, b *string) bool { return a == nil && b == nil || a != nil && b != nil && *a == *b }
func approvalSummaries(ms []approvalMember) []any {
	out := make([]any, 0, len(ms))
	for _, m := range ms {
		ids := make([]any, len(m.ImmutableRolloutIDs))
		for i, id := range m.ImmutableRolloutIDs {
			ids[i] = id
		}
		out = append(out, object{"id": m.ID, "parentId": m.ParentID, "role": m.Role, "immutableRolloutIds": ids, "sessionId": m.SessionID, "archiveEntry": m.ArchiveEntry, "originBasename": m.OriginBasename, "sourceSize": m.Source.Size, "sourceSha256": m.Source.SHA256})
	}
	return out
}
func familyApprovalMembers(f *family, root string) []approvalMember {
	ms := make([]approvalMember, len(f.Members))
	for i, m := range f.Members {
		ms[i] = approvalMember{m.ID, m.Parent, memberRole(m), m.ImmutableRolloutIDs, m.SessionID, m.ArchiveEntry, m.OriginBasename, approvalSource{filepath.Join(root, "members", fmt.Sprintf("%04d.jsonl", i)), m.Size, m.SHA256}}
	}
	return ms
}
func approvalMappingDigest(ms []approvalMember) (string, error) {
	// Convert nullable typed pointers through the same JSON decoder as the wire.
	v, e := parseJSON(encoded(approvalSummaries(ms)))
	if e != nil {
		return "", e
	}
	b, e := storeCanonicalJSON(v)
	if e != nil {
		return "", e
	}
	return digest(b), nil
}
func (l *approvalLease) Close() error {
	var result error
	for _, es := range [][]snapshotEntry{l.Files, l.Dirs} {
		for i := len(es) - 1; i >= 0; i-- {
			if es[i].File != nil {
				result = errors.Join(result, es[i].File.Close())
			}
		}
	}
	l.Files = nil
	l.Dirs = nil
	return result
}
func approvalExpired(deadline time.Time) error {
	if !time.Now().Before(deadline) {
		return fail("resourceLimit", "승인 원자료 검사 시간 초과")
	}
	return nil
}
func approvalDirectoryEntries(root string, count int) error {
	slots := map[string]bool{}
	for i := 0; i < count; i++ {
		slots[fmt.Sprintf("%04d.jsonl", i)] = true
	}
	for _, spec := range []struct {
		path  string
		count int
	}{{root, 2}, {filepath.Join(root, "members"), count}} {
		f, e := os.Open(spec.path)
		if e != nil {
			return e
		}
		entries, readErr := f.ReadDir(spec.count + 1)
		closeErr := f.Close()
		if readErr != nil && readErr != io.EOF || closeErr != nil {
			return errors.Join(readErr, closeErr)
		}
		if len(entries) != spec.count {
			return fail("approval_evidence", "승인 디렉터리 항목 수 오류")
		}
		for _, entry := range entries {
			if spec.path == root {
				if entry.Name() != "manifest.json" && entry.Name() != "members" {
					return fail("approval_evidence", "승인 디렉터리 추가 항목")
				}
			} else if !slots[entry.Name()] {
				return fail("approval_evidence", "승인 slot 이름 오류")
			}
		}
	}
	return nil
}
func approvalHash(f *os.File, max int64, deadline time.Time) (string, int64, error) {
	if _, e := f.Seek(0, io.SeekStart); e != nil {
		return "", 0, e
	}
	h := sha256.New()
	var total int64
	buffer := make([]byte, 64<<10)
	for {
		if e := approvalExpired(deadline); e != nil {
			return "", total, e
		}
		n, e := f.Read(buffer)
		if int64(n) > max-total {
			return "", total, fail("resourceLimit", "승인 원자료 크기 초과")
		}
		total += int64(n)
		h.Write(buffer[:n])
		if e == io.EOF {
			return hex.EncodeToString(h.Sum(nil)), total, nil
		}
		if e != nil {
			return "", total, e
		}
	}
}
func validateApprovalManifest(raw []byte, o options, ms []member) (approvalManifest, error) {
	var m approvalManifest
	if len(raw) > 4<<20 {
		return m, fail("resourceLimit", "승인 manifest 크기 한도 초과")
	}
	v, e := parseJSON(raw)
	if e != nil {
		return m, e
	}
	x := obj(v)
	if !exact(x, "schemaVersion", "profile", "archiveSha256", "archiveFormat", "operationId", "home", "cwd", "pins", "members") || !exact(obj(x["pins"]), "engineSha256", "normalEngineSha256", "loaderContractId") {
		return m, fail("approval_evidence", "승인 manifest 키 오류")
	}
	for _, entry := range array(x["members"]) {
		a := obj(entry)
		if !exact(a, "id", "parentId", "role", "immutableRolloutIds", "sessionId", "archiveEntry", "originBasename", "source") || !exact(obj(a["source"]), "path", "size", "sha256") {
			return m, fail("approval_evidence", "승인 member 키 오류")
		}
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if e = d.Decode(&m); e != nil {
		return m, fail("approval_evidence", "승인 manifest 타입 오류")
	}
	if m.SchemaVersion != 1 || m.Profile != approvalProfile || !hashRE.MatchString(m.ArchiveSHA256) || (m.ArchiveFormat != 1 && m.ArchiveFormat != 2) || !opRE.MatchString(o.Run) || m.OperationID != o.Run || !samePath(m.Home, o.Home) || !samePath(m.Cwd, o.Cwd) || m.Pins != (approvalPins{engineSHA256, normalEngineSHA256, loaderContractID}) || len(m.Members) != len(ms) || len(ms) < 1 || len(ms) > 2000 {
		return m, fail("approval_evidence", "승인 scope/pin 오류")
	}
	seen := map[string]bool{}
	if !hashRE.MatchString(m.Pins.EngineSHA256) || !hashRE.MatchString(m.Pins.NormalEngineSHA256) || m.Pins.LoaderContractID == "" {
		return m, fail("approval_evidence", "승인 pin 형식 오류")
	}
	var total int64
	for i, a := range m.Members {
		want := ms[i]
		if a.Source.Size != want.Size {
			return m, fail("approval_evidence", "승인 원자료 크기 결속 오류")
		}
		name := "rollout.jsonl"
		if m.ArchiveFormat == 2 {
			name = fmt.Sprintf("rollouts/%04d.jsonl", i)
		}
		basename := rolloutNameRE.FindStringSubmatch(a.OriginBasename)
		if a.ID != want.ID || seen[a.ID] || !uuidRE.MatchString(a.ID) || !sameParent(a.ParentID, want.Parent) || a.Role != memberRole(want) || i == 0 && a.ParentID != nil || i > 0 && (a.ParentID == nil || !seen[*a.ParentID]) || len(a.ImmutableRolloutIDs) != 1 || a.ImmutableRolloutIDs[0] != a.ID || len(want.ImmutableRolloutIDs) != 1 || want.ImmutableRolloutIDs[0] != a.ID || a.SessionID != want.SessionID || !uuidRE.MatchString(a.SessionID) || a.ArchiveEntry != name || a.ArchiveEntry != want.ArchiveEntry || a.OriginBasename != want.OriginBasename || filepath.Base(a.OriginBasename) != a.OriginBasename || basename == nil || basename[1] != a.ID || basename[2] != "" || !samePath(a.Source.Path, filepath.Join(filepath.Dir(approvalPath(o)), "members", fmt.Sprintf("%04d.jsonl", i))) || !hashRE.MatchString(a.Source.SHA256) || a.Source.Size < 1 || a.Source.Size > limit-total {
			return m, fail("approval_evidence", "승인 mapping/source 오류")
		}
		total += a.Source.Size
		seen[a.ID] = true
	}
	return m, nil
}
func pinApproval(o options, ms []member) (lease *approvalLease, retErr error) {
	d := o.ApprovalEvidence
	if d == nil || d.Profile != approvalProfile || !hashRE.MatchString(d.ManifestSHA256) || !samePath(d.ManifestPath, approvalPath(o)) {
		return nil, fail("approval_evidence", "승인 descriptor 누락/오류")
	}
	deadline := time.Now().Add(30 * time.Second)
	l := &approvalLease{}
	sid, sd, e := snapshotSecurity()
	if e != nil {
		return nil, e
	}
	proc("LocalFree").Call(uintptr(unsafe.Pointer(sd)))
	defer func() {
		if retErr != nil {
			retErr = errors.Join(retErr, l.Close())
		}
	}()
	parents := &dbAcquisition{}
	if e := parents.lockDirs(filepath.Join(filepath.Dir(d.ManifestPath), "members")); e != nil {
		l.Dirs = parents.Dirs
		return nil, e
	}
	l.Dirs = parents.Dirs
	root := filepath.Dir(d.ManifestPath)
	for _, path := range []string{root, filepath.Join(root, "members")} {
		if e := snapshotACL(path, sid); e != nil {
			return nil, e
		}
	}
	for _, entry := range l.Dirs {
		if samePath(entry.File.Name(), root) {
			l.Ownership.DirectoryIdentity = snapshotFileID(entry.Info)
		}
		if samePath(entry.File.Name(), filepath.Join(root, "members")) {
			l.Ownership.MemberDirectoryIdentity = snapshotFileID(entry.Info)
		}
	}
	entry, e := snapshotOpen(d.ManifestPath, false)
	if e != nil {
		return nil, e
	}
	l.Files = append(l.Files, entry)
	if e = snapshotOwnedACL(d.ManifestPath, sid, true); e != nil {
		return nil, e
	}
	h, n, e := approvalHash(entry.File, 4<<20, deadline)
	if e != nil || h != d.ManifestSHA256 || n < 1 {
		return nil, fail("approval_evidence", "승인 manifest 해시/크기 오류")
	}
	if _, e = entry.File.Seek(0, io.SeekStart); e != nil {
		return nil, e
	}
	raw, e := io.ReadAll(io.LimitReader(entry.File, (4<<20)+1))
	if e != nil {
		return nil, e
	}
	l.Manifest, e = validateApprovalManifest(raw, o, ms)
	if e != nil {
		return nil, e
	}
	if e = approvalDirectoryEntries(root, len(ms)); e != nil {
		return nil, e
	}
	l.Ownership.ManifestIdentity = snapshotFileID(entry.Info)
	for _, m := range l.Manifest.Members {
		entry, e := snapshotOpen(m.Source.Path, false)
		if e != nil {
			return nil, e
		}
		l.Files = append(l.Files, entry)
		if e = snapshotOwnedACL(m.Source.Path, sid, true); e != nil {
			return nil, e
		}
		h, n, e := approvalHash(entry.File, m.Source.Size, deadline)
		if e != nil || n != m.Source.Size || h != m.Source.SHA256 {
			return nil, fail("approval_evidence", "승인 member 실제 bytes 불일치")
		}
		if _, e = entry.File.Seek(0, io.SeekStart); e != nil {
			return nil, e
		}
		r := bufio.NewReader(entry.File)
		first := true
		for {
			if e = approvalExpired(deadline); e != nil {
				return nil, e
			}
			line, e := streamLine(r)
			if e == io.EOF && len(line) == 0 {
				break
			}
			if e != nil {
				return nil, fail("approval_evidence", "승인 member 줄/EOF 오류")
			}
			v, e := parseJSON(line)
			record := obj(v)
			header := obj(record["payload"])
			if e != nil || header == nil {
				return nil, fail("approval_evidence", "승인 member canonical 구조 오류")
			}
			if first {
				q, e := canonicalRolloutSessionID(header)
				if e != nil || record["type"] != "session_meta" || header["id"] != m.ID || q != m.SessionID || m.ParentID == nil && header["parent_thread_id"] != nil || m.ParentID != nil && header["parent_thread_id"] != *m.ParentID {
					return nil, fail("approval_evidence", "승인 member M/Q/parent 불일치")
				}
				first = false
			} else if record["type"] == "session_meta" {
				return nil, fail("approval_evidence", "승인 member 중복 header")
			}
		}
		if first {
			return nil, fail("approval_evidence", "승인 member 비어 있음")
		}
		l.Ownership.MemberIdentities = append(l.Ownership.MemberIdentities, snapshotFileID(entry.Info))
	}
	l.MappingDigest, e = approvalMappingDigest(l.Manifest.Members)
	if e != nil {
		return nil, e
	}
	return l, nil
}
func createApproval(o options, f *family) (*approvalDescriptor, *approvalOwnership, error) {
	root := filepath.Dir(approvalPath(o))
	m := approvalManifest{1, approvalProfile, f.ArchiveSHA, f.ArchiveFormat, o.Run, o.Home, o.Cwd, approvalPins{engineSHA256, normalEngineSHA256, loaderContractID}, familyApprovalMembers(f, root)}
	raw := append(encoded(m), '\n')
	if len(raw) > 4<<20 {
		return nil, nil, fail("resourceLimit", "승인 manifest 크기 한도 초과")
	}
	if _, e := validateApprovalManifest(raw, o, f.Members); e != nil {
		return nil, nil, e
	}
	if e := noReparse(root); e != nil {
		return nil, nil, e
	}
	if e := os.MkdirAll(filepath.Dir(root), 0700); e != nil {
		return nil, nil, e
	}
	for _, path := range []string{root, filepath.Join(root, "members")} {
		entry, _, _, e := createSnapshotDirectory(path)
		if entry.File != nil {
			e = errors.Join(e, entry.File.Close())
		}
		if e != nil {
			return nil, nil, e
		}
	}
	deadline := time.Now().Add(30 * time.Second)
	for i, member := range m.Members {
		if e := approvalExpired(deadline); e != nil {
			return nil, nil, e
		}
		if e := createFile(member.Source.Path, f.Members[i].Raw); e != nil {
			return nil, nil, e
		}
	}
	if e := createFile(approvalPath(o), raw); e != nil {
		return nil, nil, e
	}
	d := &approvalDescriptor{approvalProfile, approvalPath(o), digest(raw)}
	o.ApprovalEvidence = d
	l, e := pinApproval(o, f.Members)
	if e != nil {
		return nil, nil, e
	}
	ownership := l.Ownership
	if e = l.Close(); e != nil {
		return nil, nil, e
	}
	return d, &ownership, nil
}
func validateJournalApproval(j *journal, raw []byte) error {
	v, _ := parseJSON(raw)
	record := obj(v)
	if j.Version == 3 {
		if j.ApprovalEvidence != nil || j.ApprovalOwnership != nil || j.ReferenceApprovalEvidence != nil || j.ReferenceApprovalOwnership != nil || j.CleanupStatus != "" {
			return fail("unsupported_record", "v3 승인 자동 승격 금지")
		}
		for _, v := range array(record["members"]) {
			if !exact(obj(v), "id", "parent", "path", "size", "sha256") {
				return fail("unsupported_record", "v3 member 키 오류")
			}
		}
		return nil
	}
	if j.CleanupStatus != "" && j.CleanupStatus != "complete" && j.CleanupStatus != "rolled_back" {
		return fail("unsupported_record", "승인 정리 상태 오류")
	}
	if (j.ReferenceApprovalEvidence == nil) != (j.ReferenceApprovalOwnership == nil) || j.CleanupStatus != "" && j.Status != "pending" {
		return fail("unsupported_record", "승인 reference/정리 결속 오류")
	}
	if j.ApprovalEvidence == nil || j.ApprovalOwnership == nil {
		if j.Phase == "created" && j.Status == "pending" && j.ApprovalEvidence == nil && j.ApprovalOwnership == nil {
			return nil
		}
		return fail("unsupported_record", "v4 승인 근거 누락")
	}
	d := j.ApprovalEvidence
	o := j.ApprovalOwnership
	run := filepath.Base(filepath.Dir(filepath.Dir(d.ManifestPath)))
	if !opRE.MatchString(run) || !samePath(d.ManifestPath, approvalPath(options{Home: j.Home, Run: run})) {
		return fail("unsupported_record", "v4 승인 경로 containment 오류")
	}
	if !exact(obj(record["approvalEvidence"]), "profile", "manifestPath", "manifestSha256") || !exact(obj(record["approvalOwnership"]), "directoryIdentity", "memberDirectoryIdentity", "manifestIdentity", "memberIdentities") || d.Profile != approvalProfile || !hashRE.MatchString(d.ManifestSHA256) || !fileIDRE.MatchString(o.DirectoryIdentity) || !fileIDRE.MatchString(o.MemberDirectoryIdentity) || !fileIDRE.MatchString(o.ManifestIdentity) || len(o.MemberIdentities) != len(j.Members) {
		return fail("unsupported_record", "v4 승인 descriptor/ownership 오류")
	}
	if ref := j.ReferenceApprovalEvidence; ref != nil {
		owner := j.ReferenceApprovalOwnership
		refHome := filepath.Join(runPath(j.Home, run), "ref")
		if !exact(obj(record["referenceApprovalEvidence"]), "profile", "manifestPath", "manifestSha256") || !exact(obj(record["referenceApprovalOwnership"]), "directoryIdentity", "memberDirectoryIdentity", "manifestIdentity", "memberIdentities") || ref.Profile != approvalProfile || !hashRE.MatchString(ref.ManifestSHA256) || !samePath(ref.ManifestPath, approvalPath(options{Home: refHome, Run: run})) || !fileIDRE.MatchString(owner.DirectoryIdentity) || !fileIDRE.MatchString(owner.MemberDirectoryIdentity) || !fileIDRE.MatchString(owner.ManifestIdentity) || len(owner.MemberIdentities) != len(j.Members) {
			return fail("unsupported_record", "v4 reference 승인 scope/ownership 오류")
		}
		for _, id := range owner.MemberIdentities {
			if !fileIDRE.MatchString(id) {
				return fail("unsupported_record", "v4 reference identity 오류")
			}
		}
	}
	for i, m := range j.Members {
		if !fileIDRE.MatchString(o.MemberIdentities[i]) || len(m.ImmutableRolloutIDs) != 1 || m.ImmutableRolloutIDs[0] != m.ID || !uuidRE.MatchString(m.SessionID) || m.ArchiveEntry == "" || m.OriginBasename == "" || !exact(obj(array(record["members"])[i]), "id", "parent", "path", "size", "sha256", "immutableRolloutIds", "sessionId", "archiveEntry", "originBasename") {
			return fail("unsupported_record", "v4 승인 mapping 오류")
		}
	}
	return nil
}

func prepareRequest(o options, operation, n string, descriptors []any) (object, error) {
	var evidence any
	if len(descriptors) > 0 {
		d := o.ApprovalEvidence
		if d == nil || d.Profile != approvalProfile || !hashRE.MatchString(d.ManifestSHA256) || !samePath(d.ManifestPath, approvalPath(o)) {
			return nil, fail("approval_evidence", "구성원 prepare에는 원승인 descriptor가 필요합니다")
		}
		evidence = d
	} else if o.ApprovalEvidence != nil || operation != "plan" && operation != "bootstrap" {
		return nil, fail("approval_evidence", "무구성원 prepare scope 오류")
	}
	return object{"contractVersion": 2, "requestNonce": n, "operation": operation, "home": o.Home, "cwd": o.Cwd, "offline": true, "members": descriptors, "approvalEvidence": evidence}, nil
}
func validateApprovalProjection(r object, o options, ms []member, acquired bool) error {
	if r["mappingProfile"] != approvalProfile {
		return fail("approval_evidence", "승인 mapping profile 불일치")
	}
	if !acquired {
		if r["approvalEvidenceDigest"] != nil || r["approvedMappingDigest"] != nil {
			return fail("approval_evidence", "미완료 승인 digest는 null이어야 합니다")
		}
		return nil
	}
	if o.ApprovalEvidence == nil || r["approvalEvidenceDigest"] != o.ApprovalEvidence.ManifestSHA256 || !hashRE.MatchString(text(r["approvedMappingDigest"])) {
		return fail("approval_evidence", "완료 승인 digest 결속 오류")
	}
	l, e := pinApproval(o, ms)
	if e != nil {
		return e
	}
	if r["approvedMappingDigest"] != l.MappingDigest {
		return errors.Join(fail("approval_evidence", "typed 승인 mapping digest 불일치"), l.Close())
	}
	return l.Close()
}
func rpcFrame(value object) ([]byte, error) {
	b, e := json.Marshal(value)
	if e != nil {
		return nil, fail("rpc_schema", "RPC 직렬화 오류")
	}
	if len(b) > lineLimit {
		return nil, fail("rpc_limit", "RPC 전송 frame 한도 초과")
	}
	return append(b, '\n'), nil
}
func writeRPCFrame(p *process, b []byte, deadline time.Time) error {
	ch := make(chan error, 1)
	go func() {
		n, e := p.In.Write(b)
		if e == nil && n != len(b) {
			e = io.ErrShortWrite
		}
		ch <- e
	}()
	select {
	case e := <-ch:
		if !time.Now().Before(deadline) {
			return fail("rpc_timeout", "RPC 전송 시간 초과")
		}
		return e
	case <-time.After(time.Until(deadline)):
		p.close()
		return fail("rpc_timeout", "RPC 전송 시간 초과")
	}
}

func cleanupApproval(o options, ms []member, ownership *approvalOwnership) (retErr error) {
	root := filepath.Dir(approvalPath(o))
	if o.ApprovalEvidence == nil || ownership == nil {
		if _, e := os.Lstat(root); os.IsNotExist(e) {
			return nil
		}
		return fail("approval_cleanup", "기록 없는 승인 원자료는 보존합니다")
	}
	l, e := pinApproval(o, ms)
	if e != nil {
		return e
	}
	if !bytes.Equal(encoded(l.Ownership), encoded(ownership)) {
		return errors.Join(fail("approval_cleanup", "승인 원자료 identity 변경"), l.Close())
	}
	manifest := l.Manifest
	defer func() { retErr = errors.Join(retErr, l.Close()) }()
	for _, entry := range l.Files {
		e = errors.Join(e, entry.File.Close())
	}
	l.Files = nil
	if e != nil {
		return e
	}
	closeDirectory := func(path string) error {
		for i := range l.Dirs {
			if l.Dirs[i].File != nil && samePath(l.Dirs[i].File.Name(), path) {
				e := l.Dirs[i].File.Close()
				l.Dirs[i].File = nil
				return e
			}
		}
		return fail("approval_cleanup", "정리 디렉터리 lease 누락")
	}
	// Deletion uses the handle whose identity/hash were checked, not a reopened path.
	for i, m := range manifest.Members {
		if e = removeApprovalEntry(m.Source.Path, ownership.MemberIdentities[i], m.Source.SHA256, m.Source.Size, false); e != nil {
			return e
		}
	}
	if e = removeApprovalEntry(approvalPath(o), ownership.ManifestIdentity, o.ApprovalEvidence.ManifestSHA256, 4<<20, false); e != nil {
		return e
	}
	if e = closeDirectory(filepath.Join(root, "members")); e != nil {
		return e
	}
	if e = removeApprovalEntry(filepath.Join(root, "members"), ownership.MemberDirectoryIdentity, "", 0, true); e != nil {
		return e
	}
	if e = closeDirectory(root); e != nil {
		return e
	}
	if e = removeApprovalEntry(root, ownership.DirectoryIdentity, "", 0, true); e != nil {
		return e
	}
	return l.Close()
}
func removeApprovalEntry(path, id, sha string, max int64, directory bool) (retErr error) {
	u, e := syscall.UTF16PtrFromString(path)
	if e != nil {
		return e
	}
	access := uint32(syscall.GENERIC_READ | 0x10000)
	flags := uint32(0x00200000)
	if directory {
		access = 0x80 | 0x10000
		flags = 0x02200000
	}
	h, e := syscall.CreateFile(u, access, syscall.FILE_SHARE_READ, nil, syscall.OPEN_EXISTING, flags, 0)
	if e != nil {
		return e
	}
	f := os.NewFile(uintptr(h), path)
	defer func() { retErr = errors.Join(retErr, f.Close()) }()
	info, e := snapshotInfo(f, directory)
	if e != nil || snapshotFileID(info) != id {
		return fail("approval_cleanup", "정리 대상 identity 변경")
	}
	if !directory {
		hash, _, e := approvalHash(f, max, time.Now().Add(30*time.Second))
		if e != nil || hash != sha {
			return fail("approval_cleanup", "정리 대상 bytes 변경")
		}
	}
	disposition := uint32(1)
	r, _, e := proc("SetFileInformationByHandle").Call(uintptr(h), 4, uintptr(unsafe.Pointer(&disposition)), unsafe.Sizeof(disposition))
	if r == 0 {
		return e
	}
	return nil
}
func cleanupJournal(run string, j *journal, target string) error {
	if j.Version == 3 {
		return cleanup(run)
	}
	j.CleanupStatus = target
	if e := saveJournal(run, j, false); e != nil {
		return e
	}
	if j.ReferenceApprovalEvidence != nil {
		ref := options{Home: filepath.Join(run, "ref"), Cwd: j.Cwd, Run: filepath.Base(run), ApprovalEvidence: j.ReferenceApprovalEvidence}
		if e := cleanupApproval(ref, j.Members, j.ReferenceApprovalOwnership); e != nil {
			return e
		}
	} else {
		ref := options{Home: filepath.Join(run, "ref"), Run: filepath.Base(run)}
		if e := cleanupApproval(ref, j.Members, nil); e != nil {
			return e
		}
	}
	if e := cleanup(run); e != nil {
		return e
	}
	o := options{Home: j.Home, Cwd: j.Cwd, Run: filepath.Base(run), ApprovalEvidence: j.ApprovalEvidence}
	if e := cleanupApproval(o, j.Members, j.ApprovalOwnership); e != nil {
		return e
	}
	old := j.Status
	j.Status = target
	j.CleanupStatus = ""
	if e := saveJournal(run, j, false); e != nil {
		j.Status = old
		j.CleanupStatus = target
		return e
	}
	return nil
}
