package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// 실제 엔진을 실행하지 않는 체크인 fixture runner가 같은 상태 전이를 검사한다.
var prepareEngine = openEngine
var checkGuard = guard
var readState = checkDB
var readPreparedState = checkDBPrepared
var advanceJournal = advance
var stageFile = createFile

func summary(f *family) object {
	r := obj(f.Members[0].Data["thread"])
	title := text(r["name"])
	if title == "" {
		title = text(r["title"])
	}
	count := 0
	for _, m := range f.Members {
		count += len(m.Records)
	}
	return object{"sessionId": f.Members[0].ID, "title": title, "cwd": r["cwd"], "historyMode": r["history_mode"], "recordCount": count, "archived": f.Archived, "children": len(f.Members) - 1}
}
func stableProjection(p object) object {
	r := object{}
	for _, k := range []string{"contractVersion", "engineVersion", "loaderContractId", "mappingProfile", "home", "normalSqliteHome", "operationSqliteHome", "stateDb", "sqliteRedirect", "writeTargets", "proofTargets", "projectConfig", "authResolution", "policyResolution", "validity"} {
		r[k] = p[k]
	}
	return r
}
func tokenFor(o options, f *family, p object) string {
	return digest(encoded(object{"archive": f.ArchiveSHA, "archiveFormat": f.ArchiveFormat, "home": o.Home, "cwd": o.Cwd, "members": approvalSummaries(familyApprovalMembers(f, "")), "mappingProfile": approvalProfile, "route": "go", "impl": implementation, "engineSha256": engineSHA256, "normalEngineSha256": normalEngineSHA256, "normalEnginePath": o.NormalEngine, "loader": stableProjection(p)}))
}
func plan(o options) (object, error) {
	f, e := readArchive(o.Archive)
	if e != nil {
		return nil, e
	}
	r := object{"status": "unsupported", "reason": "", "reasonCode": "", "source": summary(f), "target": nil, "members": f.Members, "engineVersion": "", "projectConfig": []any{}}
	if e := support(f, o.Home); e != nil {
		r["reasonCode"] = reason(e)
		r["reason"] = e.Error()
		return r, nil
	}
	r["members"] = f.Members
	r["status"] = "blocked"
	s, e := scanHome(o.Home, f.Members, false)
	if e != nil {
		r["reasonCode"] = reason(e)
		r["reason"] = e.Error()
		return r, e
	}
	if hasFiles(s) {
		r["status"] = "exists"
		r["reasonCode"] = "exists"
		r["reason"] = "같은 ID 파일이 있습니다"
		return r, nil
	}
	prepared, e := prepareEngine(o, "plan", nil)
	if e != nil {
		return r, e
	}
	r["engineVersion"] = prepared.Projection["engineVersion"]
	r["projectConfig"] = prepared.Projection["projectConfig"]
	token := tokenFor(o, f, prepared.Projection)
	if e = prepared.Close(); e != nil {
		return r, e
	}
	r["status"] = "new"
	r["reason"] = "새 ID 대화 묶음"
	r["reasonCode"] = "new"
	r["token"] = token
	return r, nil
}
func importArchive(o options) (result object, retErr error) {
	preview, e := plan(o)
	if e != nil {
		return nil, e
	}
	if preview["status"] != "new" || text(preview["token"]) != o.Token {
		return nil, fail("stale_plan", "미리보기 경로/토큰이 바뀌었습니다")
	}
	if e = checkGuard(nil); e != nil {
		return nil, e
	}
	pending, e := pendingRuns(o.Home)
	if e != nil {
		return nil, e
	}
	if len(pending) > 0 {
		return object{"pending": pending}, fail("pending_record", "미완료 복구 기록을 먼저 처리하세요")
	}
	f, e := readArchive(o.Archive)
	if e != nil {
		return nil, e
	}
	if e = support(f, o.Home); e != nil {
		return nil, e
	}
	run := runPath(o.Home, o.Run)
	if e = noReparse(run); e != nil {
		return nil, e
	}
	if e = os.MkdirAll(filepath.Dir(run), 0700); e != nil {
		return nil, e
	}
	if e = noReparse(run); e != nil {
		return nil, e
	}
	if e = os.Mkdir(run, 0700); e != nil {
		return nil, fail("run_exists", "작업 ID를 재사용할 수 없습니다")
	}
	createdRun, e := snapshotOpen(run, true)
	if e != nil { return object{"pending": []string{o.Run}}, e }
	createdRunID := snapshotFileID(createdRun.Info)
	if e = createdRun.File.Close(); e != nil { return object{"pending": []string{o.Run}}, e }
	j := &journal{Version: 4, Impl: "ctxhop-codex", Status: "pending", Phase: "created", Home: o.Home, ID: f.Members[0].ID, Cwd: o.Cwd, ArchiveSHA256: f.ArchiveSHA, Archived: f.Archived, Members: f.Members, EngineVersion: text(preview["engineVersion"]), EngineSHA256: engineSHA256, NormalEngineSHA256: normalEngineSHA256, LoaderContractID: loaderContractID}
	if e = saveJournal(run, j, true); e != nil {
		if removeNewEmptyRun(run, createdRunID) == nil { return object{"pending": []string{}}, e }
		return object{"pending": []string{o.Run}}, e
	}
	var active *session
	defer func() {
		if active != nil {
			if e := active.Close(); e != nil {
				if retErr == nil {
					retErr = e
				}
				j.LastError = reason(e)
			} else {
				active = nil
			}
		}
		if retErr != nil {
			j.LastError = reason(retErr)
			if phases[j.Phase] < phases["placing"] && active == nil && checkGuard(nil) == nil {
				if s, e := scanHome(o.Home, j.Members, false); e == nil && !hasFiles(s) {
					if e = cleanupJournal(run, j, "rolled_back"); e == nil {
						j.Status = "rolled_back"
					}
				}
			}
			saveErr := saveJournal(run, j, false)
			if saveErr != nil {
				j.Status = "pending"
			}
			result = object{"status": j.Status, "phase": j.Phase, "run": o.Run, "pending": []string{}, "recovery": "none"}
			if j.Status == "pending" {
				result["pending"] = []string{o.Run}
				result["recovery"] = "required"
			}
		}
	}()
	staged := make([]member, len(f.Members))
	j.ApprovalEvidence, j.ApprovalOwnership, e = createApproval(o, f)
	if e != nil {
		return nil, e
	}
	o.ApprovalEvidence = j.ApprovalEvidence
	if e = saveJournal(run, j, false); e != nil {
		return nil, e
	}
	copy(staged, f.Members)
	for i, m := range f.Members {
		p := filepath.Join(run, "stage", fmt.Sprintf("%04d.jsonl", i))
		if e = stageFile(p, m.Raw); e != nil {
			return nil, e
		}
		b, e := readBounded(p, limit)
		if e != nil || digest(b) != m.SHA256 {
			return nil, fail("stage_hash", "준비 파일 해시 오류")
		}
		staged[i].Path = p
	}
	if e = advanceJournal(run, j, "staged"); e != nil {
		return nil, e
	}
	if e = bootstrapIfNeeded(o); e != nil {
		return nil, e
	}
	if e = checkGuard(nil); e != nil {
		return nil, e
	}
	active, e = prepareEngine(o, "import", staged)
	if e != nil {
		return nil, e
	}
	if tokenFor(o, f, active.Projection) != o.Token {
		return nil, fail("stale_plan", "엔진 준비 출처가 바뀌었습니다")
	}
	view, e := admit(active, o.Home, f.Members, false)
	if e != nil {
		return nil, e
	}
	for _, m := range f.Members {
		if view.IDs[m.ID] {
			return nil, fail("exists_in_engine", "파일 없이 DB에 같은 ID가 있습니다")
		}
	}
	if e = active.activate(); e != nil {
		return nil, e
	}
	for _, m := range f.Members {
		_, e = active.Call("thread/read", object{"threadId": m.ID})
		var re *rpcError
		if !asRPC(e, &re) || re.Code != -32600 {
			return nil, fail("exists_in_engine", "배치 전 ID 부재를 확인할 수 없습니다")
		}
	}
	scan, e := scanHome(o.Home, f.Members, false)
	if e != nil {
		return nil, e
	}
	if hasFiles(scan) {
		return nil, fail("exists", "배치 전 같은 ID 파일이 생겼습니다")
	}
	if e = advanceJournal(run, j, "placing"); e != nil {
		return nil, e
	}
	for i, m := range f.Members {
		if e = noReparse(m.Path); e != nil {
			return nil, e
		}
		if e = os.MkdirAll(filepath.Dir(m.Path), 0700); e != nil {
			return nil, e
		}
		if e = moveFile(staged[i].Path, m.Path, false); e != nil {
			return nil, e
		}
		if e = checkOwned(m, m.Path, o.Cwd, false); e != nil {
			return nil, e
		}
	}
	if e = advanceJournal(run, j, "placed"); e != nil {
		return nil, e
	}
	if e = register(active, f.Members); e != nil {
		return nil, e
	}
	if e = advanceJournal(run, j, "engine"); e != nil {
		return nil, e
	}
	if _, e = resumeAll(active, f.Members, o.Cwd, true); e != nil {
		return nil, e
	}
	if _, e = verifyOwned(o.Home, j, true); e != nil {
		return nil, e
	}
	if e = advanceJournal(run, j, "settled"); e != nil {
		return nil, e
	}
	title := text(summary(f)["title"])
	if title != "" {
		if _, e = active.Call("thread/name/set", object{"threadId": j.ID, "name": title}); e != nil {
			return nil, e
		}
	}
	j.TerminalProof = obj(cloneJSON(active.Projection))
	if e = active.Close(); e != nil {
		return nil, e
	}
	active = nil
	if e = checkGuard(nil); e != nil {
		return nil, e
	}
	active, e = prepareEngine(o, "cold", currentMembers(o.Home, j))
	if e != nil {
		return nil, e
	}
	if _, e = admit(active, o.Home, j.Members, false); e != nil {
		return nil, e
	}
	if e = active.activate(); e != nil {
		return nil, e
	}
	if e = checkMetadata(active, f, o.Cwd); e != nil {
		return nil, e
	}
	cold, e := resumeAll(active, f.Members, o.Cwd, false)
	if e != nil {
		return nil, e
	}
	actual, e := histories(active, f)
	if e != nil {
		return nil, e
	}
	if _, e = verifyOwned(o.Home, j, true); e != nil {
		return nil, e
	}
	j.TerminalProof = obj(cloneJSON(active.Projection))
	if e = active.Close(); e != nil {
		return nil, e
	}
	active = nil
	reference, e := referenceHistory(o, f, run, j)
	if e != nil {
		return nil, e
	}
	if !bytes.Equal(encoded(actual), encoded(reference)) {
		return nil, fail("history_mismatch", "대상과 참조 이력이 다릅니다")
	}
	if e = checkGuard(nil); e != nil {
		return nil, e
	}
	if e = advanceJournal(run, j, "verified"); e != nil {
		return nil, e
	}
	if f.Archived {
		active, e = prepareEngine(o, "cold", currentMembers(o.Home, j))
		if e != nil {
			return nil, e
		}
		if _, e = admit(active, o.Home, j.Members, false); e != nil {
			return nil, e
		}
		if e = active.activate(); e != nil {
			return nil, e
		}
		if _, e = active.Call("thread/archive", object{"threadId": j.ID}); e != nil {
			return nil, e
		}
		if e = checkMetadata(active, f, o.Cwd); e != nil {
			return nil, e
		}
		if e = advanceJournal(run, j, "archived"); e != nil {
			return nil, e
		}
		if _, e = verifyOwned(o.Home, j, true); e != nil {
			return nil, e
		}
		j.TerminalProof = obj(cloneJSON(active.Projection))
	if e = active.Close(); e != nil {
			return nil, e
		}
		active = nil
	}
	if e = checkGuard(nil); e != nil {
		return nil, e
	}
	if _, e = readState(o.Home, filepath.Join(o.Home, "state_5.sqlite"), j.Members, false); e != nil {
		return nil, e
	}
	if e = cleanupJournal(run, j, "complete"); e != nil {
		return nil, e
	}
	j.Status = "complete"
	if e = saveJournal(run, j, false); e != nil {
		j.Status = "pending"
		return nil, e
	}
	return object{"status": "imported", "members": j.Members, "engineVersion": j.EngineVersion, "run": o.Run, "pending": []string{}, "recovery": "none", "coldSandbox": cold}, nil
}
func admit(s *session, home string, ms []member, missing bool) (view dbView, retErr error) {
	if e := checkGuard(s.P); e != nil {
		return dbView{}, e
	}
	if e := checkOtherStoreAbsence(s.Projection); e != nil {
		return dbView{}, e
	}
	view, e := readPreparedState(home, text(s.Projection["stateDb"]), ms, missing)
	if e != nil {
		return view, e
	}
	defer func() {
		if view.Acquisition != nil {
			// Failed provider completion cannot prove private readers drained.
			// Preserve that private namespace for attention; still drain raw leases.
			retErr = errors.Join(retErr, view.Acquisition.Close(retErr == nil))
		}
	}()
	if s.Operation == "rollback" || s.Operation == "rollback-check" {
		for _, m := range s.Members {
			if _, e := os.Stat(m.Path); os.IsNotExist(e) {
				if view.IDs[m.ID] {
					return view, fail("missing_rollout_metadata", "파일 없이 DB 행이 남은 구성원")
				}
				for _, edge := range view.Edges {
					if text(edge["parent_thread_id"]) == m.ID || text(edge["child_thread_id"]) == m.ID {
						return view, fail("missing_rollout_metadata", "없는 구성원의 DB 연결이 남았습니다")
					}
				}
			} else if e != nil {
				return view, e
			}
		}
	}
	if e = s.complete(view); e != nil {
		return view, e
	}
	if view.Acquisition != nil {
		if e := view.Acquisition.VerifyPrivate(); e != nil {
			return view, e
		}
		if e := view.Acquisition.Close(true); e != nil {
			return view, e
		}
		s.Acquisition = view.Acquisition
	}
	if e := s.revalidateHandoff(); e != nil {
		return view, e
	}
	return view, nil
}
func currentMembers(home string, j *journal) []member {
	m := append([]member(nil), j.Members...)
	for i := range m {
		p := m[i].Path
		if _, e := os.Stat(p); os.IsNotExist(e) {
			p = filepath.Join(home, "archived_sessions", filepath.Base(p))
		}
		m[i].Path = p
		if b, e := readBounded(p, limit); e == nil {
			m[i].SHA256 = digest(b)
		}
	}
	return m
}
func bootstrapIfNeeded(o options) error {
	path := filepath.Join(o.Home, "state_5.sqlite")
	if _, e := os.Stat(path); e == nil {
		return nil
	} else if !os.IsNotExist(e) {
		return e
	}
	s, e := scanHome(o.Home, nil, false)
	if e != nil {
		return e
	}
	if len(s.All) > 0 {
		return fail("engine_db_unknown", "기존 롤아웃 홈의 DB 부재")
	}
	dbs, e := filepath.Glob(filepath.Join(o.Home, "*.sqlite*"))
	if e != nil || len(dbs) > 0 {
		return fail("engine_db_unknown", "새 홈 bootstrap을 증명할 수 없습니다")
	}
	if e = checkGuard(nil); e != nil {
		return e
	}
	bootstrap := o
	bootstrap.ApprovalEvidence = nil
	bootstrap.RecoveryEvidence = nil
	sesh, e := prepareEngine(bootstrap, "bootstrap", nil)
	if e != nil {
		return e
	}
	defer sesh.Close()
	if e = checkGuard(sesh.P); e != nil {
		return e
	}
	if _, e = readState(o.Home, text(sesh.Projection["stateDb"]), nil, true); e != nil {
		return e
	}
	if e = sesh.activate(); e != nil {
		return e
	}
	if e = sesh.Close(); e != nil {
		return e
	}
	if e = checkGuard(nil); e != nil {
		return e
	}
	_, e = readState(o.Home, path, nil, false)
	return e
}
func register(s *session, members []member) error {
	for i := len(members) - 1; i >= 0; i-- {
		m := members[i]
		r, e := s.Call("thread/read", object{"threadId": m.ID})
		if e != nil {
			return e
		}
		t := obj(r["thread"])
		if text(t["id"]) != m.ID || !parentMatches(t, m) {
			return fail("parent_mismatch", "등록 부모 연결 불일치")
		}
	}
	return nil
}
func parentMatches(t object, m member) bool {
	if m.Parent == nil {
		return t["parentThreadId"] == nil
	}
	return text(t["parentThreadId"]) == *m.Parent
}
func resumeAll(s *session, members []member, cwd string, first bool) (object, error) {
	sandboxes := object{}
	for _, m := range members {
		p := object{"threadId": m.ID, "excludeTurns": true}
		if first {
			p["cwd"] = cwd
			p["approvalPolicy"] = "untrusted"
			p["approvalsReviewer"] = "user"
			p["sandbox"] = "read-only"
		}
		r, e := s.Call("thread/resume", p)
		if e != nil {
			return nil, e
		}
		if text(r["approvalPolicy"]) != "untrusted" || text(r["approvalsReviewer"]) != "user" || !samePath(text(r["cwd"]), cwd) || !parentMatches(obj(r["thread"]), m) || text(obj(r["thread"])["id"]) != m.ID {
			return nil, fail("resume_settings", "resume 정책/cwd/부모 불일치")
		}
		sb := obj(r["sandbox"])
		kind := text(sb["type"])
		if kind == "" || first && kind != "readOnly" {
			return nil, fail("resume_settings", "첫 resume read-only 불일치")
		}
		sandboxes[m.ID] = sb
	}
	return sandboxes, nil
}
func checkMetadata(s *session, f *family, cwd string) error {
	for i, m := range f.Members {
		r, e := s.Call("thread/read", object{"threadId": m.ID})
		if e != nil {
			return e
		}
		t := obj(r["thread"])
		if text(t["id"]) != m.ID || !parentMatches(t, m) || !samePath(text(t["cwd"]), cwd) {
			return fail("metadata_mismatch", "cold/read 메타데이터 불일치")
		}
		if i == 0 && text(summary(f)["title"]) != "" && text(t["name"]) != text(summary(f)["title"]) && text(t["title"]) != text(summary(f)["title"]) {
			return fail("title_mismatch", "원래 제목을 확인할 수 없습니다")
		}
	}
	return nil
}
func histories(s *session, f *family) (object, error) {
	r := object{}
	for _, m := range f.Members {
		p := object{"threadId": m.ID}
		legacy := text(obj(m.Data["thread"])["history_mode"]) == "legacy"
		if legacy {
			p["itemsView"] = "full"
		}
		turns, e := pages(s, "thread/turns/list", p, "data")
		if e != nil {
			return nil, e
		}
		var items []any
		if !legacy {
			items, e = pages(s, "thread/items/list", object{"threadId": m.ID}, "data")
			if e != nil {
				return nil, e
			}
		}
		user := false
		for _, rec := range m.Records {
			p := obj(rec["payload"])
			if text(rec["type"]) == "event_msg" && text(p["type"]) == "user_message" {
				user = true
			}
		}
		if user && len(turns) == 0 {
			return nil, fail("history_empty", "사용자 이력이 있지만 턴이 없습니다")
		}
		r[m.ID] = object{"turns": turns, "items": items}
	}
	return r, nil
}
func referenceHistory(o options, f *family, run string, j *journal) (object, error) {
	home := filepath.Join(run, "ref")
	if e := os.Mkdir(home, 0700); e != nil {
		return nil, e
	}
	config := []byte("[features]\nlocal_thread_store_compression = false\nbackground_paginated_rollout_migration = false\nplugins = false\n")
	if e := createFile(filepath.Join(home, "config.toml"), config); e != nil {
		return nil, e
	}
	ref := o
	ref.Home = home
	ref.ApprovalEvidence = nil
	d, ownership, e := createApproval(ref, f)
	if e != nil {
		return nil, e
	}
	ref.ApprovalEvidence = d
	j.ReferenceApprovalEvidence = d
	j.ReferenceApprovalOwnership = ownership
	if e = saveJournal(run, j, false); e != nil {
		return nil, e
	}
	if e := bootstrapIfNeeded(ref); e != nil {
		return nil, e
	}
	ms := append([]member(nil), f.Members...)
	for i, m := range ms {
		ms[i].Path = filepath.Join(home, "sessions", filepath.Base(m.Path))
	}
	staged := append([]member(nil), ms...)
	for i, m := range ms {
		staged[i].Path = filepath.Join(home, "stage", fmt.Sprintf("%04d.jsonl", i))
		if e := createFile(staged[i].Path, m.Raw); e != nil {
			return nil, e
		}
	}
	if e := checkGuard(nil); e != nil {
		return nil, e
	}
	s, e := prepareEngine(ref, "reference", staged)
	if e != nil {
		return nil, e
	}
	defer s.Close()
	view, e := admit(s, home, ms, false)
	if e != nil {
		return nil, e
	}
	for _, m := range ms {
		if view.IDs[m.ID] {
			return nil, fail("reference_exists", "참조 DB ID 충돌")
		}
	}
	if e = s.activate(); e != nil {
		return nil, e
	}
	for i, m := range ms {
		if e = os.MkdirAll(filepath.Dir(m.Path), 0700); e != nil {
			return nil, e
		}
		if e = moveFile(staged[i].Path, m.Path, false); e != nil {
			return nil, e
		}
	}
	if e = register(s, ms); e != nil {
		return nil, e
	}
	if _, e = resumeAll(s, ms, o.Cwd, true); e != nil {
		return nil, e
	}
	for _, m := range ms {
		if e = checkOwned(m, m.Path, o.Cwd, true); e != nil {
			return nil, e
		}
	}
	if e = s.Close(); e != nil {
		return nil, e
	}
	if e = checkGuard(nil); e != nil {
		return nil, e
	}
	cold := append([]member(nil), ms...)
	for i := range cold {
		b, e := readBounded(cold[i].Path, limit)
		if e != nil {
			return nil, e
		}
		cold[i].SHA256 = digest(b)
	}
	s, e = prepareEngine(ref, "cold", cold)
	if e != nil {
		return nil, e
	}
	defer s.Close()
	if _, e = admit(s, home, ms, false); e != nil {
		return nil, e
	}
	if e = s.activate(); e != nil {
		return nil, e
	}
	if _, e = resumeAll(s, ms, o.Cwd, false); e != nil {
		return nil, e
	}
	r, e := histories(s, f)
	if e != nil {
		return nil, e
	}
	for _, m := range ms {
		if e = checkOwned(m, m.Path, o.Cwd, true); e != nil {
			return nil, e
		}
	}
	if e = s.Close(); e != nil {
		return nil, e
	}
	if e = checkGuard(nil); e != nil {
		return nil, e
	}
	return r, nil
}
func rollback(o options) (result object, retErr error) {
	j, e := loadJournal(o.Home, o.Run)
	if e != nil {
		return nil, e
	}
	if j.LocalFinalization != nil { return finalizeLocal(o.Home, o.Run) }
	if e := checkGuard(nil); e != nil { return nil, e }
	if j.Status == "rolled_back" {
		return object{"status": "rolled_back", "run": o.Run, "pending": []string{}}, nil
	}
	if j.Status != "pending" {
		return nil, fail("unsupported_record", "pending 기록만 되돌릴 수 있습니다")
	}
	phase, ok := phases[j.Phase]
	if !ok {
		return nil, fail("unsupported_record", "알 수 없는 복구 단계")
	}
	run := runPath(o.Home, o.Run)
	scan, e := verifyOwned(o.Home, j, false)
	if e != nil {
		return object{"status": "needs_attention", "pending": []string{o.Run}}, e
	}
	if phase < phases["placing"] && !hasFiles(scan) {
		if e = cleanupJournal(run, j, "rolled_back"); e != nil {
			return nil, e
		}
		j.Status = "rolled_back"
		if e = saveJournal(run, j, false); e != nil {
			return nil, e
		}
		return object{"status": "rolled_back", "pending": []string{}, "run": o.Run}, nil
	}
	if j.EngineSHA256 != engineSHA256 || j.NormalEngineSHA256 != normalEngineSHA256 || j.LoaderContractID != loaderContractID {
		return nil, fail("engine_untrusted", "복구 기록의 protected engine pin이 바뀌었습니다")
	}
	if j.Version == 3 {
		return object{"status": "needs_attention", "pending": []string{o.Run}}, fail("approval_evidence", "v3 복구의 승인 source/profile 재확보가 필요합니다")
	}
	if j.CleanupStatus != "" {
		return object{"status": "needs_attention", "pending": []string{o.Run}}, fail("approval_cleanup", "미완료 evidence 정리를 수동 확인하세요")
	}
	o.Cwd = j.Cwd
	o.ApprovalEvidence = j.ApprovalEvidence
	o.RecoveryEvidence = j.RecoveryEvidence
	ms := currentMembers(o.Home, j)
	s, recovered, e := prepareRecoveryEngine(o, j, ms)
	o = recovered
	if e != nil {
		return object{"status": "needs_attention", "pending": []string{o.Run}}, e
	}
	defer func() {
		if e := s.Close(); e != nil {
			if retErr == nil {
				retErr = e
			}
		}
		if retErr != nil {
			j.LastError = reason(retErr)
			j.Status = "pending"
			saveJournal(run, j, false)
			result = object{"status": "needs_attention", "pending": []string{o.Run}, "run": o.Run}
		}
	}()
	before, e := admit(s, o.Home, j.Members, false)
	if e != nil {
		return nil, e
	}
	for _, m := range j.Members {
		if len(scan.Files[m.ID]) == 0 && before.IDs[m.ID] {
			return nil, fail("missing_rollout_metadata", "파일 없는 DB 행은 안전한 삭제 context를 증명할 수 없습니다")
		}
	}
	if _, e = verifyOwned(o.Home, j, false); e != nil {
		return nil, e
	}
	if e = s.activate(); e != nil {
		return nil, e
	}
	ids := map[string]bool{}
	for _, m := range j.Members {
		ids[m.ID] = true
	}
	for _, archived := range []bool{false, true} {
		rows, e := pages(s, "thread/list", object{"archived": archived, "useStateDbOnly": true, "sourceKinds": []string{"cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"}}, "data")
		if e != nil {
			return nil, e
		}
		for _, v := range rows {
			t := obj(v)
			if ids[text(t["parentThreadId"])] && !ids[text(t["id"])] {
				return nil, fail("foreign_link", "API에 묶음 밖 하위 대화")
			}
		}
	}
	for _, m := range j.Members {
		if !before.IDs[m.ID] && len(scan.Files[m.ID]) == 0 {
			continue
		}
		a, e := pages(s, "thread/attachment/list", object{"threadId": m.ID}, "data")
		if e != nil {
			return nil, e
		}
		if len(a) > 0 {
			return nil, fail("attachments", "사용자가 추가한 첨부가 있습니다")
		}
	}
	scan, e = verifyOwned(o.Home, j, false)
	if e != nil {
		return nil, e
	}
	rootPresent := len(scan.Files[j.ID]) > 0
	r, readErr := s.Call("thread/read", object{"threadId": j.ID})
	if readErr == nil {
		if text(obj(r["thread"])["id"]) != j.ID {
			return nil, fail("rpc_schema", "root read ID 오류")
		}
		rootPresent = true
	} else {
		var re *rpcError
		if !asRPC(readErr, &re) || re.Code != -32600 {
			return nil, readErr
		}
	}
	if rootPresent {
		_, _ = s.Call("thread/delete", object{"threadId": j.ID})
	} else {
		for i := len(j.Members) - 1; i >= 1; i-- {
			m := j.Members[i]
			if len(scan.Files[m.ID]) > 0 || before.IDs[m.ID] {
				if _, e = s.Call("thread/delete", object{"threadId": m.ID}); e != nil {
					break
				}
			}
		}
	}
	if e = s.Close(); e != nil {
		return nil, e
	}
	if e = checkGuard(nil); e != nil {
		return nil, e
	}
	after, e := readState(o.Home, filepath.Join(o.Home, "state_5.sqlite"), j.Members, false)
	if e != nil {
		return nil, e
	}
	final, e := scanHome(o.Home, j.Members, true)
	if e != nil {
		return nil, e
	}
	if hasFiles(final) {
		return nil, fail("delete_incomplete", "삭제 후 구성원 파일이 남았습니다")
	}
	count := 0
	for _, m := range j.Members {
		if after.IDs[m.ID] {
			return nil, fail("delete_incomplete", "삭제 후 구성원 DB 행이 남았습니다")
		}
		if before.IDs[m.ID] {
			count++
		}
	}
	if before.Count-after.Count != count {
		return nil, fail("delete_scope", "삭제 전후 DB 행 차이가 구성원 수와 다릅니다")
	}
	for id := range before.IDs {
		if !ids[id] && !after.IDs[id] {
			return nil, fail("delete_scope", "구성원 밖 DB 행이 없어졌습니다")
		}
	}
	for _, edge := range after.Edges {
		if ids[text(edge["parent_thread_id"])] || ids[text(edge["child_thread_id"])] {
			return nil, fail("delete_incomplete", "삭제 후 구성원 연결이 남았습니다")
		}
	}
	for path, hash := range scan.All {
		if !ids[rolloutID(path)] {
			if final.All[path] != hash {
				return nil, fail("delete_scope", "구성원 밖 파일이 바뀌었습니다")
			}
		}
	}
	if e = verifyAbsentAPI(o, j); e != nil {
		return nil, e
	}
	finalDB, e := readState(o.Home, filepath.Join(o.Home, "state_5.sqlite"), j.Members, false)
	if e != nil {
		return nil, e
	}
	if !bytes.Equal(encoded(finalDB.IDs), encoded(after.IDs)) || !bytes.Equal(encoded(finalDB.Edges), encoded(after.Edges)) {
		return nil, fail("delete_scope", "마지막 API 검사 중 DB 대상/연결 변경")
	}
	if e = cleanupJournal(run, j, "rolled_back"); e != nil {
		return nil, e
	}
	j.Status = "rolled_back"
	if e = saveJournal(run, j, false); e != nil {
		return nil, e
	}
	return object{"status": "rolled_back", "run": o.Run, "pending": []string{}}, nil
}
func rolloutID(path string) string {
	m := rolloutNameRE.FindStringSubmatch(filepath.Base(path))
	if m == nil {
		return ""
	}
	return m[1]
}
func verifyAbsentAPI(o options, j *journal) error {
	o.ApprovalEvidence = j.ApprovalEvidence
	if e := checkGuard(nil); e != nil {
		return e
	}
	s, e := prepareEngine(o, "rollback-check", currentMembers(o.Home, j))
	if e != nil {
		return e
	}
	defer s.Close()
	v, e := admit(s, o.Home, j.Members, false)
	if e != nil {
		return e
	}
	for _, m := range j.Members {
		if v.IDs[m.ID] {
			return fail("delete_incomplete", "마지막 API 전 구성원 DB 행")
		}
	}
	if e = s.activate(); e != nil {
		return e
	}
	for _, m := range j.Members {
		_, e := s.Call("thread/read", object{"threadId": m.ID})
		var re *rpcError
		if !asRPC(e, &re) || re.Code != -32600 {
			return fail("delete_incomplete", "마지막 API 부재 확인 실패")
		}
	}
	if e = s.Close(); e != nil {
		return e
	}
	j.TerminalProof = obj(cloneJSON(s.Projection))
	if e = checkGuard(nil); e != nil {
		return e
	}
	scan, e := scanHome(o.Home, j.Members, true)
	if e != nil {
		return e
	}
	if hasFiles(scan) {
		return fail("delete_incomplete", "마지막 API 후 구성원 파일")
	}
	return nil
}
