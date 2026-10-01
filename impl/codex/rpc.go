package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type rpcError struct {
	Code    int64
	Message string
	Data    object
}

func (e *rpcError) Error() string { return fmt.Sprintf("엔진 RPC 오류 (%d)", e.Code) } // engine의 비밀 포함 오류 문자열은 전달하지 않는다.
type session struct {
	P           *process
	Projection  object
	Binding     object
	Members     []member
	Options     options
	Operation   string
	Acquisition *dbAcquisition
	Evidence    *approvalLease
	Call        func(string, object) (object, error)
	Notify      func(string, object) error
	Close       func() error
}

func enginePath(o options) (string, error) {
	path := o.Engine
	if path == "" {
		exe, e := os.Executable()
		if e != nil {
			return "", e
		}
		path = filepath.Join(filepath.Dir(exe), "engine", "ctxhop-codex-engine.exe")
	}
	path, e := absolute(path)
	if e != nil {
		return "", e
	}
	if !hashRE.MatchString(engineSHA256) || !strings.HasPrefix(loaderContractID, "ctxhop-prestart-v2:") || len(loaderContractID) == len("ctxhop-prestart-v2:") {
		return "", fail("engine_untrusted", "검증된 protected engine 배포 pin이 없습니다")
	}
	if !strings.EqualFold(filepath.Base(path), "ctxhop-codex-engine.exe") {
		return "", fail("engine_identity", "guard가 인식하는 protected engine 이름이 필요합니다")
	}
	return path, nil
}
func normalEnginePath(o options) (string, error) {
	if !hashRE.MatchString(normalEngineSHA256) {
		return "", fail("normal_engine_untrusted", "정상 엔진의 검증된 배포 pin이 없습니다")
	}
	if o.NormalEngine != "" {
		return absolute(o.NormalEngine)
	}
	root := os.Getenv("LOCALAPPDATA")
	if !filepath.IsAbs(root) {
		return "", fail("normal_engine_untrusted", "정상 엔진 설치 경로 미확정")
	}
	matches, e := filepath.Glob(filepath.Join(root, "OpenAI", "Codex", "bin", "*", "codex.exe"))
	if e != nil || len(matches) == 0 {
		return "", fail("normal_engine_untrusted", "정상 Codex Desktop 엔진을 찾을 수 없습니다")
	}
	type candidate struct {
		path string
		time time.Time
	}
	candidates := []candidate{}
	for _, p := range matches {
		if e = noReparse(p); e != nil {
			return "", e
		}
		st, e := os.Stat(p)
		if e != nil || !st.Mode().IsRegular() {
			return "", fail("normal_engine_untrusted", "정상 엔진 파일 오류")
		}
		candidates = append(candidates, candidate{p, st.ModTime()})
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].time.Equal(candidates[j].time) {
			return candidates[i].path < candidates[j].path
		}
		return candidates[i].time.After(candidates[j].time)
	})
	return candidates[0].path, nil
}
func processEnv(home string) ([]string, error) {
	env := []string{}
	for _, s := range os.Environ() {
		k, _, _ := strings.Cut(s, "=")
		if strings.HasPrefix(strings.ToUpper(k), "CTXHOP_") {
			continue
		}
		switch strings.ToUpper(k) {
		case "CODEX_SQLITE_HOME":
			return nil, fail("engine_db_unknown", "CODEX_SQLITE_HOME 재지정은 지원하지 않습니다")
		case "CODEX_APP_SERVER_TEST_USER_CONFIG_FILE":
			return nil, fail("engine_db_unknown", "테스트 설정 주입 환경은 지원하지 않습니다")
		case "CODEX_HOME":
			continue
		}
		env = append(env, s)
	}
	return append(env, "CODEX_HOME="+home), nil
}
func openEngine(o options, operation string, members []member) (*session, error) {
	image, e := enginePath(o)
	if e != nil {
		return nil, e
	}
	locks, e := lockImage(image)
	if e != nil {
		return nil, e
	}
	keepLocks := false
	defer func() {
		if !keepLocks {
			for _, f := range locks {
				f.Close()
			}
		}
	}()
	b, e := io.ReadAll(io.LimitReader(locks[0], limit+1))
	if e != nil || int64(len(b)) > limit || digest(b) != engineSHA256 {
		return nil, fail("engine_untrusted", "protected engine 열린 handle 해시가 pin과 다릅니다")
	}
	normal, e := normalEnginePath(o)
	if e != nil {
		return nil, e
	}
	normalLocks, e := lockImage(normal)
	if e != nil {
		return nil, e
	}
	locks = append(locks, normalLocks...)
	b, e = io.ReadAll(io.LimitReader(normalLocks[0], limit+1))
	if e != nil || int64(len(b)) > limit || digest(b) != normalEngineSHA256 {
		return nil, fail("normal_engine_untrusted", "정상 엔진 열린 handle 해시가 pin과 다릅니다")
	}
	env, e := processEnv(o.Home)
	if e != nil {
		return nil, e
	}
	var evidence *approvalLease
	if len(members) > 0 {
		evidence, e = pinApproval(o, members)
		if e != nil {
			return nil, e
		}
	} else if o.ApprovalEvidence != nil {
		return nil, fail("approval_evidence", "무구성원 prepare의 승인 descriptor는 null이어야 합니다")
	}
	keepEvidence := false
	defer func() {
		if !keepEvidence && evidence != nil {
			evidence.Close()
		}
	}()
	p, e := startProcess(image, o.Cwd, env)
	if e != nil {
		return nil, e
	}
	p.ImageLocks = locks
	keepLocks = true
	s := &session{P: p, Evidence: evidence}
	s.Close = func() error {
		e := p.close()
		if e == nil && s.Evidence != nil {
			e = s.Evidence.Close()
			s.Evidence = nil
		}
		return e
	}
	reader := bufio.NewReader(p.Out)
	id := int64(0)
	var mu sync.Mutex
	// stderr는 수집/출력하지 않고 제한된 pipe를 계속 비워 비밀을 남기지 않는다.
	go io.Copy(io.Discard, p.Err)
	s.Notify = func(method string, params object) error {
		mu.Lock()
		defer mu.Unlock()
		frame, e := rpcFrame(object{"method": method, "params": params})
		if e != nil {
			return e
		}
		return writeRPCFrame(p, frame, time.Now().Add(30*time.Second))
	}
	s.Call = func(method string, params object) (object, error) {
		mu.Lock()
		defer mu.Unlock()
		id++
		deadline := time.Now().Add(30 * time.Second)
		request := object{"id": id, "method": method, "params": params}
		frame, e := rpcFrame(request)
		if e != nil {
			return nil, e
		}
		if e := writeRPCFrame(p, frame, deadline); e != nil {
			return nil, fail("rpc_io", "RPC 전송 실패")
		}
		type result struct {
			m object
			e error
		}
		ch := make(chan result, 1)
		go func() {
			for n := 0; n < 10000; n++ {
				b, e := streamLine(reader)
				if e != nil {
					ch <- result{e: fail("rpc_eof", "RPC 읽기 실패")}
					return
				}
				v, e := parseJSON(b)
				if e != nil {
					ch <- result{e: e}
					return
				}
				m := obj(v)
				rid, hasID := integer(m["id"])
				if m == nil {
					ch <- result{e: fail("rpc_schema", "RPC frame 오류")}
					return
				}
				if _, ok := m["method"]; ok {
					if hasID {
						ch <- result{e: fail("server_request", "엔진 서버 요청은 수용하지 않습니다")}
						return
					}
					if !exact(m, "method", "params") {
						ch <- result{e: fail("rpc_schema", "notification frame 오류")}
						return
					}
					continue
				}
				if !hasID || rid != id {
					ch <- result{e: fail("rpc_binding", "RPC 응답 ID 오류")}
					return
				}
				if er, ok := m["error"]; ok {
					if !exact(m, "id", "error") {
						ch <- result{e: fail("rpc_schema", "RPC 오류 frame 오류")}
						return
					}
					code, ok := integer(obj(er)["code"])
					_, messageOK := obj(er)["message"].(string)
					if !ok || !messageOK || !exact(obj(er), "code", "message") && !exact(obj(er), "code", "message", "data") {
						ch <- result{e: fail("rpc_schema", "RPC 오류 code 오류")}
						return
					}
					ch <- result{e: &rpcError{code, text(obj(er)["message"]), obj(obj(er)["data"])}}
					return
				}
				if !exact(m, "id", "result") || obj(m["result"]) == nil {
					ch <- result{e: fail("rpc_schema", "RPC result 구조 오류")}
					return
				}
				ch <- result{m: obj(m["result"])}
				return
			}
			ch <- result{e: fail("rpc_limit", "notification 한도 초과")}
		}()
		select {
		case r := <-ch:
			if !time.Now().Before(deadline) {
				return nil, fail("rpc_timeout", "RPC 응답 시간 초과")
			}
			return r.m, r.e
		case <-time.After(time.Until(deadline)):
			p.close()
			return nil, fail("rpc_timeout", "RPC 응답 시간 초과")
		}
	}
	requestNonce := nonce()
	descriptors := []any{}
	for _, m := range members {
		path := any(m.Path)
		sha := any(m.SHA256)
		if _, e := os.Stat(m.Path); os.IsNotExist(e) {
			path = nil
			sha = nil
		} else if e != nil {
			p.close()
			return nil, e
		}
		role := "root"
		if m.Parent != nil {
			role = "child"
		}
		descriptors = append(descriptors, object{"id": m.ID, "parentId": m.Parent, "role": role, "rolloutPath": path, "rolloutSha256": sha})
	}
	params, e := prepareRequest(o, operation, requestNonce, descriptors)
	if e != nil {
		p.close()
		return nil, e
	}
	r, e := s.Call("ctxhop/prepare", params)
	if e != nil {
		p.close()
		var re *rpcError
		if asRPC(e, &re) && text(re.Data["reasonCode"]) != "" {
			return nil, fail(text(re.Data["reasonCode"]), "protected engine 준비가 안전하게 거절됐습니다")
		}
		return nil, e
	}
	checkMembers := members
	if operation != "plan" && operation != "bootstrap" {
		checkMembers = nil
		if r["inputComplete"] != false {
			p.close()
			return nil, fail("prestart_schema", "DB 관측 전 member snapshot 완성 금지")
		}
	}
	if e = validateProjection(r, requestNonce, operation, o, checkMembers, int64(p.PID), nil); e != nil {
		p.close()
		return nil, e
	}
	s.Members = members
	s.Options = o
	s.Operation = operation
	s.Projection = r
	s.bind()
	p.prepared = true
	keepEvidence = true
	return s, nil
}
func (s *session) bind() {
	s.Binding = object{}
	for _, k := range []string{"contractVersion", "requestNonce", "processNonce", "snapshotId", "generation", "projectionDigest"} {
		s.Binding[k] = s.Projection[k]
	}
	s.Binding["operation"] = s.Operation
}
func (s *session) complete(observed dbView) error {
	if observed.Acquisition != nil && observed.Acquisition.Aggregate != nil {
		return fail("engine_db_unknown", "실제8 schema·metadata·strict inventory 검증 전 운영 complete 금지")
	}
	if s.Projection["inputComplete"] == true {
		return nil
	}
	// Production admission remains closed until the actual eight-store schema,
	// canonical metadata and strict file inventory are wired. A v1 state view is
	// never promoted. The same v2 adapter is exercised by protocol-only fixtures.
	if s.P != nil || observed.Acquisition != nil {
		return fail("engine_db_unknown", "검증된 v2 전체 store proof가 없는 운영 complete 금지")
	}
	observation := observed.StoreObservation
	targets, e := validateStoreTargetsV2(s.Projection["proofTargets"], s.Options.Home)
	if e != nil {
		return e
	}
	d, e := validateStoreObservationV2(observation, s.Options.Home, targets)
	if e != nil {
		return e
	}
	local := object{"acquisitionId": observation["acquisitionId"], "storeObservationDigest": d, "storeProof": observed.StoreProof}
	if e = validateStoreBindingsV2(local, observation, s.Options.Home, targets, s.Members, true); e != nil {
		return e
	}
	localProof, e := storeCanonicalJSON(observed.StoreProof)
	if e != nil {
		return e
	}
	if e = validateRPCBindingV2(s.Binding); e != nil {
		return e
	}
	params := object{}
	for k, v := range s.Binding {
		params[k] = v
	}
	params["storeObservation"] = observation
	r, e := s.Call("ctxhop/complete", params)
	if e != nil {
		return e
	}
	oldGen, _ := integer(s.Projection["generation"])
	newGen, _ := integer(r["generation"])
	if newGen <= oldGen || text(r["processNonce"]) != text(s.Projection["processNonce"]) || text(r["snapshotId"]) != text(s.Projection["snapshotId"]) || r["inputComplete"] != true || r["acquisitionId"] != observation["acquisitionId"] {
		return fail("prestart_binding", "최종 complete binding 오류")
	}
	pid, _ := integer(s.Projection["processId"])
	if e = validateProjection(r, text(s.Projection["requestNonce"]), s.Operation, s.Options, s.Members, pid, observation); e != nil {
		return e
	}
	providerProof, e := storeCanonicalJSON(r["storeProof"])
	if e != nil {
		return e
	}
	if !bytes.Equal(providerProof, localProof) {
		return fail("prestart_binding", "Go/provider typed store proof 불일치")
	}
	s.Projection = r
	s.bind()
	return nil
}
func asRPC(e error, out **rpcError) bool {
	r, ok := e.(*rpcError)
	if ok {
		*out = r
	}
	return ok
}

func validateObservation(raw object, state string) error {
	// The local native builder uses Go integers; normalize through the same
	// duplicate/type-rejecting JSON representation used by the pipe protocol.
	v, e := parseJSON(encoded(raw))
	if e != nil {
		return e
	}
	o := obj(v)
	a := obj(o["acquisition"])
	src, private := obj(a["source"]), obj(a["private"])
	version, vok := integer(a["schemaVersion"])
	bad := func() error { return fail("engine_db_unknown", "complete acquisition descriptor 오류") }
	if !exact(o, "stateDb", "mainSha256", "walSha256", "acquisition") || !samePath(text(o["stateDb"]), state) || !exact(a, "schemaVersion", "acquisitionId", "source", "private", "rollbackJournalAbsent") || !vok || version != 1 || !opRE.MatchString(text(a["acquisitionId"])) || a["rollbackJournalAbsent"] != true || !exact(src, "directoryIdentity", "main", "wal", "shm") || !exact(private, "directory", "directoryIdentity", "main", "wal") {
		return bad()
	}
	dir := text(private["directory"])
	if !filepath.IsAbs(dir) || within(filepath.Dir(state), dir) || within(dir, filepath.Dir(state)) || !fileIDRE.MatchString(text(src["directoryIdentity"])) || !fileIDRE.MatchString(text(private["directoryIdentity"])) || src["directoryIdentity"] == private["directoryIdentity"] {
		return bad()
	}
	identities := map[string]bool{text(src["directoryIdentity"]): true, text(private["directoryIdentity"]): true}
	var total int64
	for _, name := range []string{"main", "wal", "shm"} {
		if src[name] == nil {
			if name == "main" || name == "wal" && (private[name] != nil || o["walSha256"] != nil) {
				return bad()
			}
			continue
		}
		file := obj(src[name])
		size, sok := integer(file["size"])
		bound := limit
		if name == "shm" {
			bound = lineLimit
		}
		if !exact(file, "identity", "size", "sha256") || !sok || size < 0 || size > bound || !fileIDRE.MatchString(text(file["identity"])) || identities[text(file["identity"])] || !hashRE.MatchString(text(file["sha256"])) {
			return bad()
		}
		identities[text(file["identity"])] = true
		if name == "shm" {
			continue
		}
		total += size
		if total > limit || name == "main" && size < 100 {
			return bad()
		}
		copy := obj(private[name])
		n, nok := integer(copy["size"])
		if !exact(copy, "identity", "size", "sha256") || !nok || n != size || copy["sha256"] != file["sha256"] || !fileIDRE.MatchString(text(copy["identity"])) || identities[text(copy["identity"])] {
			return bad()
		}
		identities[text(copy["identity"])] = true
		outer := "mainSha256"
		if name == "wal" {
			outer = "walSha256"
		}
		if o[outer] != file["sha256"] {
			return bad()
		}
	}
	return nil
}
func validateProjection(r object, n, operation string, o options, members []member, pid int64, observation object) error {
	if !exact(r, "contractVersion", "requestNonce", "processId", "processNonce", "snapshotId", "generation", "engineVersion", "loaderContractId", "inputComplete", "home", "normalSqliteHome", "operationSqliteHome", "stateDb", "sqliteRedirect", "writeTargets", "proofTargets", "projectConfig", "contexts", "authResolution", "policyResolution", "validity", "projectionDigest", "acquisitionId", "storeObservationDigest", "storeProof", "effects", "mappingProfile", "approvalEvidenceDigest", "approvedMappingDigest") {
		return fail("prestart_schema", "알 수 없는 prepare projection 구조")
	}
	version, ok := integer(r["contractVersion"])
	processID, pok := integer(r["processId"])
	gen, gok := integer(r["generation"])
	partial := r["inputComplete"] == false && len(members) == 0 && operation != "plan" && operation != "bootstrap"
	if !ok || version != 2 || !pok || processID != pid || !gok || gen < 1 || text(r["requestNonce"]) != n || text(r["processNonce"]) == "" || text(r["snapshotId"]) == "" || !hashRE.MatchString(text(r["projectionDigest"])) || !strings.HasPrefix(loaderContractID, "ctxhop-prestart-v2:") || len(loaderContractID) == len("ctxhop-prestart-v2:") || text(r["loaderContractId"]) != loaderContractID || !versionAllowed(text(r["engineVersion"])) || r["inputComplete"] != true && !partial || r["sqliteRedirect"] != false {
		return fail("prestart_binding", "prepare binding/입력 완전성 오류")
	}
	for _, k := range []string{"home", "normalSqliteHome", "operationSqliteHome"} {
		if !samePath(text(r[k]), o.Home) {
			return fail("engine_db_unknown", "정상/작업 DB 경로가 대상 홈과 다릅니다")
		}
	}
	if !samePath(text(r["stateDb"]), filepath.Join(o.Home, "state_5.sqlite")) {
		return fail("engine_db_unknown", "state DB descriptor 불명")
	}
	effects := obj(r["effects"])
	writes, wok := integer(effects["applicationWrites"])
	network, nok := integer(effects["networkRequests"])
	acquired := r["inputComplete"] == true && operation != "plan" && operation != "bootstrap"
	if e := validateApprovalProjection(r, o, members, acquired); e != nil {
		return e
	}
	if !exact(effects, "applicationWrites", "networkRequests", "sqliteShmMayChange", "privateSqliteSidecarsMayChange") || !wok || !nok || writes != 0 || network != 0 || effects["sqliteShmMayChange"] != false || effects["privateSqliteSidecarsMayChange"] != acquired || acquired && !opRE.MatchString(text(r["acquisitionId"])) || !acquired && r["acquisitionId"] != nil {
		return fail("prestart_effects", "준비 단계 효과0 조건 실패")
	}
	if text(r["authResolution"]) != "resolved" || text(r["policyResolution"]) != "resolved" {
		return fail("prestart_resolution", "인증/정책 출처 미확정")
	}
	valid := obj(r["validity"])
	if !exact(valid, "kind", "revision", "expiresAt") || text(valid["kind"]) != "normal-loader-semantics" || text(valid["revision"]) == "" {
		return fail("prestart_validity", "정상 loader 유효성 계약 오류")
	}
	if valid["expiresAt"] != nil {
		t, e := time.Parse(time.RFC3339, text(valid["expiresAt"]))
		if e != nil || !time.Now().Before(t) {
			return fail("prestart_expired", "준비 정책 유효기간 오류")
		}
	}
	targets, e := validateStoreTargetsV2(r["proofTargets"], o.Home)
	if e != nil {
		return e
	}
	writesTargets, e := validateStoreTargetsV2(r["writeTargets"], o.Home)
	if e != nil {
		return e
	}
	for i, target := range targets {
		if !samePath(target.Path, writesTargets[i].Path) {
			return fail("prestart_targets", "proof/write descriptor 불일치")
		}
		if e := noReparse(target.Path); e != nil {
			return e
		}
		if e := noReparse(writesTargets[i].Path); e != nil {
			return e
		}
	}
	storeBinding := object{"acquisitionId": r["acquisitionId"], "storeObservationDigest": r["storeObservationDigest"], "storeProof": r["storeProof"]}
	var rawObservation any
	if observation != nil {
		rawObservation = observation
	}
	if e := validateStoreBindingsV2(storeBinding, rawObservation, o.Home, targets, members, acquired); e != nil {
		return e
	}
	projects := array(r["projectConfig"])
	if projects == nil {
		return fail("prestart_schema", "projectConfig 목록 오류")
	}
	for _, v := range projects {
		p := obj(v)
		if !exact(p, "path", "applied", "warning") || !filepath.IsAbs(text(p["path"])) || (p["applied"] != true && p["applied"] != false) {
			return fail("prestart_schema", "projectConfig 구조 오류")
		}
		if _, ok := p["warning"].(string); !ok && p["warning"] != nil {
			return fail("prestart_schema", "projectConfig 경고 구조 오류")
		}
	}
	contexts := array(r["contexts"])
	if len(contexts) < 1 {
		return fail("prestart_context", "startup context 누락")
	}
	seen := map[string]bool{}
	startup := false
	ids := map[string]member{}
	for _, m := range members {
		ids[m.ID] = m
	}
	for _, v := range contexts {
		c := obj(v)
		if !exact(c, "memberId", "ownerId", "phase", "cwd", "rolloutSha256", "settingsDigest", "contextId", "sqliteHome") || text(c["contextId"]) == "" || !samePath(text(c["sqliteHome"]), o.Home) || !samePath(text(c["cwd"]), o.Cwd) {
			return fail("prestart_context", "context 경로/구조 오류")
		}
		phase := text(c["phase"])
		if phase == "startup" {
			if startup || c["memberId"] != nil || c["ownerId"] != nil || c["rolloutSha256"] != nil || c["settingsDigest"] != nil {
				return fail("prestart_context", "startup context 오류")
			}
			startup = true
			continue
		}
		id := text(c["memberId"])
		m, ok := ids[id]
		if (operation == "rollback" || operation == "rollback-check") && ok && phase != "rollbackAbsent" {
			if _, e := os.Stat(m.Path); os.IsNotExist(e) {
				return fail("prestart_context", "없는 구성원은 rollbackAbsent marker가 필요합니다")
			}
		}
		if phase == "rollbackAbsent" {
			if (operation != "rollback" && operation != "rollback-check") || !ok || seen[id] || text(c["ownerId"]) != id || c["rolloutSha256"] != nil || c["settingsDigest"] != nil {
				return fail("prestart_context", "rollback 부재 marker 오류")
			}
			if _, e := os.Stat(m.Path); !os.IsNotExist(e) {
				return fail("prestart_context", "marker 파일 부재 불일치")
			}
			seen[id] = true
			continue
		}
		if !ok || seen[id] || text(c["ownerId"]) != id && (m.Parent == nil || text(c["ownerId"]) != *m.Parent) || text(c["rolloutSha256"]) != m.SHA256 || !hashRE.MatchString(text(c["settingsDigest"])) {
			return fail("prestart_context", "구성원 context binding 오류")
		}
		allowed := phase == "firstResume" && (operation == "import") || phase == "coldResume" && operation == "cold" || phase == "reference" && operation == "reference" || phase == "firstResume" && operation == "reference" || phase == "coldResume" && operation == "reference" || phase == "firstResume" && (operation == "rollback" || operation == "rollback-check")
		if !allowed {
			return fail("prestart_context", "승인되지 않은 context phase")
		}
		seen[id] = true
	}
	if !startup || len(seen) != len(members) {
		return fail("prestart_context", "승인 context 누락")
	}
	return nil
}
func (s *session) revalidateHandoff() error {
	if len(s.Members) > 0 {
		l, e := pinApproval(s.Options, s.Members)
		if e != nil {
			return e
		}
		if s.Evidence != nil && !bytes.Equal(encoded(l.Ownership), encoded(s.Evidence.Ownership)) {
			return errors.Join(fail("approval_evidence", "준비 후 승인 identity 변경"), l.Close())
		}
		if e = l.Close(); e != nil {
			return e
		}
	}
	if e := checkGuard(s.P); e != nil {
		return e
	}
	if s.Operation != "plan" && s.Operation != "bootstrap" {
		if e := checkOtherStoreAbsence(s.Projection); e != nil {
			return e
		}
	}
	if s.Acquisition != nil {
		if e := s.Acquisition.VerifyReleasedSource(); e != nil {
			return fail("engine_db_changed", "acquisition 해제 후 원본 변경/접근 오류")
		}
	} else if s.P != nil && s.Operation != "plan" && s.Operation != "bootstrap" {
		return fail("prestart_incomplete", "정리된 acquisition 없는 member activation 금지")
	}
	if s.P != nil && s.Operation == "bootstrap" {
		if e := snapshotAbsent(text(s.Projection["stateDb"])); e != nil {
			return fail("engine_db_changed", "bootstrap 전 state 부재 변경")
		}
	}
	for _, m := range s.Members {
		b, e := readBounded(m.Path, limit)
		absent := (s.Operation == "rollback" || s.Operation == "rollback-check") && os.IsNotExist(e)
		if absent {
			found := false
			for _, raw := range array(s.Projection["contexts"]) {
				context := obj(raw)
				if context["memberId"] == m.ID && context["phase"] == "rollbackAbsent" {
					found = true
				}
			}
			if found {
				continue
			}
		}
		if e != nil || digest(b) != m.SHA256 {
			return fail("stale_input", "accept/activate 전 rollout 입력 변경")
		}
	}
	// Canonical Config/auth/loader freshness is revalidated by the provider's
	// accept/activate against its retained typed inputs, not reconstructed here.
	return nil
}
func checkOtherStoreAbsence(projection object) error {
	// No original SQLite opens for other stores. Until their own schema and
	// references have acquisition evidence, presence is unknown and blocks.
	paths := []string{filepath.Join(filepath.Dir(text(projection["stateDb"])), "agent_message_board_1.sqlite")}
	for _, raw := range array(projection["writeTargets"]) {
		target := obj(raw)
		if target["kind"] == "state" {
			continue
		}
		paths = append(paths, text(target["path"]))
	}
	for _, path := range paths {
		for _, suffix := range []string{"", "-wal", "-shm", "-journal"} {
			if e := noReparse(path + suffix); e != nil {
				return e
			}
			if e := snapshotAbsent(path + suffix); e != nil {
				return fail("foreign_store_unknown", "다른 DB store/queue의 참조·목표 부재가 미증명입니다")
			}
		}
	}
	// Future or unrecognized SQLite namespaces cannot silently count as empty.
	state := text(projection["stateDb"])
	files, e := filepath.Glob(filepath.Join(filepath.Dir(state), "*.sqlite*"))
	if e != nil {
		return fail("foreign_store_unknown", "DB namespace 열거 실패")
	}
	for _, path := range files {
		if samePath(path, state) || samePath(path, state+"-wal") || samePath(path, state+"-shm") || samePath(path, state+"-journal") {
			continue
		}
		return fail("foreign_store_unknown", "알 수 없는 SQLite namespace의 참조·목표 부재가 미증명입니다")
	}
	return nil
}
func (s *session) activate() error {
	if s.Projection["inputComplete"] != true {
		return fail("prestart_incomplete", "complete 전 activate 금지")
	}
	if e := validateRPCBindingV2(s.Binding); e != nil {
		return e
	}
	for _, step := range []struct{ method, key string }{{"ctxhop/accept", "accepted"}, {"ctxhop/activate", "activated"}} {
		if e := s.revalidateHandoff(); e != nil {
			return e
		}
		r, e := s.Call(step.method, s.Binding)
		if e != nil {
			return e
		}
		if !exact(r, "contractVersion", "requestNonce", "processNonce", "snapshotId", "generation", "projectionDigest", "operation", step.key) || r[step.key] != true {
			return fail("activation_binding", "activation 승인 누락")
		}
		for k, v := range s.Binding {
			if string(encoded(r[k])) != string(encoded(v)) {
				return fail("activation_binding", "activation binding 불일치")
			}
		}
	}
	if s.P != nil {
		s.P.prepared = false
	}
	_, e := s.Call("initialize", object{"clientInfo": object{"name": "ctxhop-codex", "version": implementation}, "capabilities": object{}})
	if e != nil {
		return e
	}
	return s.Notify("initialized", object{})
}
func pages(s *session, method string, params object, key string) ([]any, error) {
	all := []any{}
	cursor := ""
	seen := map[string]bool{}
	for n := 0; n < 100000; n++ {
		p := object{}
		for k, v := range params {
			p[k] = v
		}
		p["limit"] = 100
		if cursor != "" {
			p["cursor"] = cursor
		}
		r, e := s.Call(method, p)
		if e != nil {
			return nil, e
		}
		items := array(r[key])
		if items == nil {
			return nil, fail("rpc_page", "페이지 데이터 구조 오류")
		}
		all = append(all, items...)
		if len(all) > 1000000 {
			return nil, fail("rpc_limit", "페이지 한도 초과")
		}
		v := r["nextCursor"]
		if v == nil {
			return all, nil
		}
		cursor = text(v)
		if cursor == "" || seen[cursor] || len(items) == 0 {
			return nil, fail("rpc_page", "페이지 cursor 진행 오류")
		}
		seen[cursor] = true
	}
	return nil, fail("rpc_limit", "페이지 횟수 초과")
}

var _ = json.Number("")
