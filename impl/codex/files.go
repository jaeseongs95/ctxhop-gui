package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type homeScan struct {
	Files map[string][]string
	All   map[string]string
}

func scanHome(home string, members []member, own bool) (homeScan, error) {
	s := homeScan{map[string][]string{}, map[string]string{}}
	ids := map[string]bool{}
	for _, m := range members {
		ids[m.ID] = true
	}
	for _, dir := range []string{"sessions", "archived_sessions"} {
		root := filepath.Join(home, dir)
		if e := noReparse(root); e != nil {
			return s, e
		}
		if _, e := os.Stat(root); os.IsNotExist(e) {
			continue
		} else if e != nil {
			return s, e
		}
		e := filepath.WalkDir(root, func(path string, d os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if e := noReparse(path); e != nil {
				return e
			}
			if d.IsDir() {
				return nil
			}
			name := d.Name()
			if !strings.HasPrefix(name, "rollout-") || (!strings.HasSuffix(name, ".jsonl") && !strings.HasSuffix(name, ".jsonl.zst")) {
				return nil
			}
			var named string
			for id := range ids {
				if strings.Contains(name, id) {
					if named != "" {
						return fail("unreadable_rollout", "파일 이름에 여러 ID")
					}
					named = id
				}
			}
			if strings.HasSuffix(name, ".zst") {
				if named != "" && !own {
					s.Files[named] = append(s.Files[named], path)
					return nil
				}
				return fail("compressed_rollouts", "압축 롤아웃은 안전 확인할 수 없습니다")
			}
			raw, e := readBounded(path, limit)
			if e != nil {
				return e
			}
			scanner := bufio.NewScanner(bytes.NewReader(raw))
			scanner.Buffer(make([]byte, 4096), lineLimit+1)
			first := true
			var headerID string
			for scanner.Scan() {
				line := scanner.Bytes()
				if len(bytes.TrimSpace(line)) == 0 {
					continue
				}
				v, e := parseJSON(line)
				if e != nil {
					return fail("unreadable_rollout", "대상 롤아웃을 읽을 수 없습니다")
				}
				r := obj(v)
				p := obj(r["payload"])
				if p == nil {
					return fail("unreadable_rollout", "대상 롤아웃 구조 오류")
				}
				if first {
					if text(r["type"]) != "session_meta" || !uuidRE.MatchString(text(p["id"])) {
						return fail("unreadable_rollout", "대상 첫 헤더 오류")
					}
					headerID = text(p["id"])
					first = false
				}
				if text(r["type"]) == "session_meta" {
					hid := text(p["id"])
					if ids[hid] && hid != named {
						if own {
							return fail("foreign_link", "다른 이름에 구성원 헤더")
						}
						s.Files[hid] = append(s.Files[hid], path)
					}
					if !ids[hid] && references(p, ids) {
						return fail("foreign_link", "묶음 밖 롤아웃이 구성원을 참조합니다")
					}
				}
			}
			if e := scanner.Err(); e != nil {
				return fail("unreadable_rollout", "대상 롤아웃 줄 한도 오류")
			}
			if first {
				return fail("unreadable_rollout", "빈 롤아웃")
			}
			if named != "" {
				if own {
					m := rolloutNameRE.FindStringSubmatch(name)
					if m == nil || m[1] != named || m[2] != "" || headerID != named {
						return fail("foreign_link", "구성원 롤아웃 이름/헤더 오류")
					}
				}
				s.Files[named] = append(s.Files[named], path)
			}
			s.All[path] = digest(raw)
			return nil
		})
		if e != nil {
			return s, e
		}
	}
	for _, files := range s.Files {
		if own && len(files) > 1 {
			return s, fail("foreign_link", "구성원 파일이 여러 개입니다")
		}
	}
	return s, nil
}
func references(h object, ids map[string]bool) bool {
	for _, key := range []string{"parent_thread_id", "session_id", "forked_from_id"} {
		if ids[text(h[key])] {
			return true
		}
	}
	if ids[text(obj(h["history_base"])["thread_id"])] {
		return true
	}
	var walk func(any) bool
	walk = func(v any) bool {
		if m := obj(v); m != nil {
			for k, v := range m {
				if (k == "parent_thread_id" || k == "thread_id" || k == "session_id") && ids[text(v)] {
					return true
				}
				if walk(v) {
					return true
				}
			}
		}
		for _, v := range array(v) {
			if walk(v) {
				return true
			}
		}
		return false
	}
	return walk(h["source"])
}
func hasFiles(s homeScan) bool {
	for _, a := range s.Files {
		if len(a) > 0 {
			return true
		}
	}
	return false
}
func createFile(path string, b []byte) error {
	if e := noReparse(path); e != nil {
		return e
	}
	if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return e
	}
	if e := noReparse(path); e != nil {
		return e
	}
	f, e := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return e
	}
	_, e = f.Write(b)
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	return e
}

type journal struct {
	Version                    int                 `json:"version"`
	Impl                       string              `json:"impl"`
	Status                     string              `json:"status"`
	Phase                      string              `json:"phase"`
	Home                       string              `json:"home"`
	ID                         string              `json:"id"`
	Cwd                        string              `json:"cwd"`
	ArchiveSHA256              string              `json:"archiveSha256"`
	Archived                   bool                `json:"archived"`
	Members                    []member            `json:"members"`
	EngineVersion              string              `json:"engineVersion"`
	EngineSHA256               string              `json:"engineSha256"`
	NormalEngineSHA256         string              `json:"normalEngineSha256"`
	LoaderContractID           string              `json:"loaderContractId"`
	LastError                  string              `json:"lastError,omitempty"`
	ApprovalEvidence           *approvalDescriptor `json:"approvalEvidence,omitempty"`
	ApprovalOwnership          *approvalOwnership  `json:"approvalOwnership,omitempty"`
	ReferenceApprovalEvidence  *approvalDescriptor `json:"referenceApprovalEvidence,omitempty"`
	ReferenceApprovalOwnership *approvalOwnership  `json:"referenceApprovalOwnership,omitempty"`
	CleanupStatus              string              `json:"cleanupStatus,omitempty"`
}

func runPath(home, run string) string { return filepath.Join(home, ".ctxhop-desktop-recovery", run) }
func saveJournal(run string, j *journal, initial bool) error {
	value := any(j)
	if j.Version == 3 {
		v, _ := parseJSON(encoded(j))
		r := obj(v)
		ms := []any{}
		for _, m := range j.Members {
			ms = append(ms, object{"id": m.ID, "parent": m.Parent, "path": m.Path, "size": m.Size, "sha256": m.SHA256})
		}
		r["members"] = ms
		value = r
	}
	data := append(encoded(value), '\n')
	if len(data) > 4<<20 {
		return fail("resourceLimit", "복구 기록 크기 한도 초과")
	}
	if e := noReparse(run); e != nil {
		return e
	}
	tmp := filepath.Join(run, "journal.tmp")
	if !initial {
		if e := noReparse(tmp); e != nil {
			return e
		}
		if e := os.Remove(tmp); e != nil && !os.IsNotExist(e) {
			return e
		}
	}
	if e := createFile(tmp, data); e != nil {
		return e
	}
	return moveFile(tmp, filepath.Join(run, "journal.json"), !initial)
}
func loadJournal(home, run string) (*journal, error) {
	p := runPath(home, run)
	b, e := readBounded(filepath.Join(p, "journal.json"), 4<<20)
	if e != nil {
		return nil, fail("unreadable", "복구 기록을 읽을 수 없습니다")
	}
	j, e := decodeJournal(home, b)
	if e == nil && j.ApprovalEvidence != nil && !samePath(j.ApprovalEvidence.ManifestPath, approvalPath(options{Home: home, Run: run})) {
		return nil, fail("unsupported_record", "복구 기록의 승인 operation 경로 오류")
	}
	return j, e
}
func decodeJournal(home string, b []byte) (*journal, error) {
	var e error
	if _, e = parseJSON(b); e != nil {
		return nil, e
	}
	var j journal
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if e = d.Decode(&j); e != nil {
		return nil, fail("unreadable", "복구 기록 구조 오류")
	}
	if (j.Version != 3 && j.Version != 4) || j.Impl != "ctxhop-codex" || !samePath(j.Home, home) || !uuidRE.MatchString(j.ID) || len(j.Members) == 0 || j.ID != j.Members[0].ID || !hashRE.MatchString(j.ArchiveSHA256) {
		return nil, fail("unsupported_record", "복구 기록 계약 오류")
	}
	if _, ok := phases[j.Phase]; !ok || (j.Status != "pending" && j.Status != "complete" && j.Status != "rolled_back") || len(j.Members) > 2000 {
		return nil, fail("unsupported_record", "복구 상태/단계 오류")
	}
	seen := map[string]bool{}
	for _, m := range j.Members {
		if !uuidRE.MatchString(m.ID) || seen[m.ID] || m.Size < 1 || m.Size > limit || !hashRE.MatchString(m.SHA256) || !within(filepath.Join(home, "sessions"), m.Path) || filepath.Base(m.Path) == "" {
			return nil, fail("unsupported_record", "복구 구성원 오류")
		}
		match := rolloutNameRE.FindStringSubmatch(filepath.Base(m.Path))
		if match == nil || match[1] != m.ID || match[2] != "" {
			return nil, fail("unsupported_record", "복구 경로 오류")
		}
		seen[m.ID] = true
	}
	if !filepath.IsAbs(j.Cwd) {
		return nil, fail("unsupported_record", "복구 cwd 오류")
	}
	if e := validateJournalApproval(&j, b); e != nil {
		return nil, e
	}
	return &j, nil
}

var phases = map[string]int{"created": 0, "staged": 1, "placing": 2, "placed": 3, "engine": 4, "settled": 5, "verified": 6, "archived": 7}

func advance(run string, j *journal, phase string) error {
	n, ok := phases[phase]
	old, known := phases[j.Phase]
	if !ok || !known || n < old || n > old+1 {
		return fail("journal_phase", "잘못된 단계 전이")
	}
	j.Phase = phase
	return saveJournal(run, j, false)
}
func cleanup(run string) error {
	for _, name := range []string{"stage", "ref"} {
		p := filepath.Join(run, name)
		if !within(run, p) {
			return fail("invalid_path", "정리 경로 오류")
		}
		if e := checkTree(p); e != nil {
			return e
		}
		if e := os.RemoveAll(p); e != nil {
			return e
		}
	}
	return nil
}
func checkTree(root string) error {
	if e := noReparse(root); e != nil {
		return e
	}
	if _, e := os.Stat(root); os.IsNotExist(e) {
		return nil
	} else if e != nil {
		return e
	}
	return filepath.WalkDir(root, func(p string, d os.DirEntry, e error) error {
		if e != nil {
			return e
		}
		return noReparse(p)
	})
}
func checkOwned(m member, path, cwd string, requireFirst bool) error {
	raw, e := readBounded(path, limit)
	if e != nil {
		return e
	}
	if int64(len(raw)) < m.Size || digest(raw[:m.Size]) != m.SHA256 {
		return fail("user_append", "원본 prefix가 바뀌었습니다")
	}
	tail := raw[m.Size:]
	if len(tail) == 0 {
		if requireFirst {
			return fail("settings_missing", "첫 설정 기록 누락")
		}
		return nil
	}
	if tail[len(tail)-1] != '\n' {
		return fail("user_append", "불완전한 추가 기록")
	}
	for i, line := range bytes.Split(tail[:len(tail)-1], []byte{'\n'}) {
		if len(line) > lineLimit {
			return fail("user_append", "추가 기록 한도 오류")
		}
		v, e := parseJSON(line)
		if e != nil {
			return fail("user_append", "추가 기록 오류")
		}
		r := obj(v)
		p := obj(r["payload"])
		s := obj(p["thread_settings"])
		if text(r["type"]) != "event_msg" || text(p["type"]) != "thread_settings_applied" || text(p["thread_id"]) != m.ID || s == nil || text(s["approval_policy"]) != "untrusted" || text(s["approvals_reviewer"]) != "user" || text(s["cwd"]) != cwd {
			return fail("user_append", "사용자 추가 기록 또는 다른 설정")
		}
		roots := array(s["runtime_workspace_roots"])
		if len(roots) != 1 || text(roots[0]) != cwd {
			return fail("settings_roots", "작업 루트 설정 오류")
		}
		if i == 0 {
			if s["active_permission_profile"] != nil {
				return fail("settings_profile", "첫 active profile은 None이어야 합니다")
			}
			pp := obj(s["permission_profile"])
			fs := obj(pp["file_system"])
			entries := array(fs["entries"])
			if text(pp["type"]) != "managed" || text(pp["network"]) != "restricted" || text(fs["type"]) != "restricted" || len(entries) == 0 {
				return fail("settings_profile", "첫 read-only 프로필 구조 오류")
			}
			for _, v := range entries {
				if text(obj(v)["access"]) != "read" {
					return fail("settings_profile", "첫 프로필에 쓰기 권한")
				}
			}
		}
	}
	return nil
}
func verifyOwned(home string, j *journal, first bool) (homeScan, error) {
	s, e := scanHome(home, j.Members, true)
	if e != nil {
		return s, e
	}
	for _, m := range j.Members {
		paths := s.Files[m.ID]
		if len(paths) > 1 {
			return s, fail("foreign_link", "중복 파일")
		}
		if len(paths) == 0 {
			if first {
				return s, fail("rollout_missing", "구성원 파일 누락")
			}
			continue
		}
		expected := m.Path
		if j.Archived && j.Phase == "archived" {
			expected = filepath.Join(home, "archived_sessions", filepath.Base(m.Path))
		}
		if !samePath(paths[0], expected) && !samePath(paths[0], filepath.Join(home, "archived_sessions", filepath.Base(m.Path))) {
			return s, fail("foreign_link", "기록 밖 구성원 파일")
		}
		if e := checkOwned(m, paths[0], j.Cwd, first); e != nil {
			return s, e
		}
	}
	return s, nil
}
func pendingRuns(home string) ([]string, error) {
	root := filepath.Join(home, ".ctxhop-desktop-recovery")
	if e := checkTree(root); e != nil {
		return nil, e
	}
	entries, e := os.ReadDir(root)
	if os.IsNotExist(e) {
		return []string{}, nil
	}
	if e != nil {
		return nil, e
	}
	out := []string{}
	for _, d := range entries {
		if !d.IsDir() {
			continue
		}
		if !opRE.MatchString(d.Name()) {
			return nil, fail("pending_record", "복구 작업 폴더 이름 불명")
		}
		run := filepath.Join(root, d.Name())
		live, resolved := filepath.Join(run, "journal.json"), filepath.Join(run, "journal.resolved.json")
		present := []string{}
		for _, path := range []string{live, resolved} {
			if _, e := os.Lstat(path); e == nil {
				present = append(present, path)
			} else if !os.IsNotExist(e) {
				return nil, fail("pending_record", "복구 기록 이름 확인 실패")
			}
		}
		if len(present) != 1 {
			return nil, fail("pending_record", "단일 복구 기록 누락/중복")
		}
		closed := present[0] == resolved
		b, e := readRecoveryRecord(present[0], !closed)
		if e != nil {
			return nil, fail("pending_record", "읽을 수 없는 복구 기록")
		}
		if closed {
			// GUI resolve is an explicit user closure, including corrupt JSON.
			// Preserve its bounded regular file; its contents grant no authority.
			continue
		}
		v, e := parseJSON(b)
		if e != nil {
			return nil, fail("pending_record", "복구 기록 JSON 오류")
		}
		record := obj(v)
		if !samePath(text(record["home"]), home) || !uuidRE.MatchString(text(record["id"])) {
			return nil, fail("pending_record", "복구 기록 home/id 결속 오류")
		}
		if record["impl"] == "ctxhop-codex" {
			if _, e := decodeJournal(home, b); e != nil {
				return nil, fail("pending_record", "Go 복구 기록 계약 오류")
			}
		} else if record["impl"] != nil {
			return nil, fail("pending_record", "알 수 없는 복구 구현")
		} else if record["version"] != nil {
			version, ok := integer(record["version"])
			if !ok || version != 2 || len(array(record["members"])) == 0 {
				return nil, fail("pending_record", "기존 복구 기록 형식 불명")
			}
		}
		switch record["status"] {
		case "pending":
			out = append(out, d.Name())
		case "complete", "rolled_back":
		default:
			return nil, fail("pending_record", "복구 기록 상태 불명")
		}
	}
	return out, nil
}

func readRecoveryRecord(path string, contents bool) (b []byte, retErr error) {
	entry, e := snapshotOpen(path, false)
	if e != nil {
		return nil, e
	}
	defer func() { retErr = errors.Join(retErr, entry.File.Close()) }()
	info, e := entry.File.Stat()
	if e != nil || !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > 4<<20 {
		return nil, fail("pending_record", "복구 기록 파일 형식/크기 오류")
	}
	if !contents {
		return nil, nil
	}
	b, e = io.ReadAll(io.LimitReader(entry.File, (4<<20)+1))
	if e != nil || len(b) > 4<<20 || int64(len(b)) != info.Size() {
		return nil, fail("pending_record", "복구 기록 읽기/크기 변경")
	}
	return b, nil
}
func streamLine(r *bufio.Reader) ([]byte, error) {
	var b []byte
	for {
		part, e := r.ReadSlice('\n')
		complete := e == nil
		if complete {
			part = part[:len(part)-1]
		}
		if len(part) > lineLimit-len(b) {
			return nil, fail("rpc_limit", "RPC 줄 한도 초과")
		}
		b = append(b, part...)
		if len(b) > lineLimit {
			return nil, fail("rpc_limit", "RPC 줄 한도 초과")
		}
		if complete {
			return b, nil
		}
		if e != bufio.ErrBufferFull {
			if e == io.EOF && len(b) > 0 {
				return nil, io.ErrUnexpectedEOF
			}
			return nil, e
		}
	}
}

var _ = io.EOF
