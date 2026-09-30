package main

import (
	"bufio"
	"bytes"
	"encoding/json"
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
	P          *process
	Projection object
	Binding    object
	Members    []member
	Options    options
	Operation  string
	Call       func(string, object) (object, error)
	Notify     func(string, object) error
	Close      func() error
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
	if !hashRE.MatchString(engineSHA256) || loaderContractID == "" {
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
		switch strings.ToUpper(k) {
		case "CODEX_SQLITE_HOME":
			return nil, fail("engine_db_unknown", "CODEX_SQLITE_HOME 재지정은 지원하지 않습니다")
		case "CODEX_APP_SERVER_TEST_USER_CONFIG_FILE":
			return nil, fail("engine_db_unknown", "테스트 설정 주입 환경은 지원하지 않습니다")
		case "CODEX_HOME", "TEMP", "TMP":
			continue
		}
		env = append(env, s)
	}
	return append(env, "CODEX_HOME="+home, "TEMP=D:\\Go\\temp", "TMP=D:\\Go\\temp"), nil
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
	p, e := startProcess(image, o.Cwd, env)
	if e != nil {
		return nil, e
	}
	p.ImageLocks = locks
	keepLocks = true
	s := &session{P: p}
	s.Close = p.close
	reader := bufio.NewReader(p.Out)
	id := int64(0)
	var mu sync.Mutex
	// stderr는 수집/출력하지 않고 제한된 pipe를 계속 비워 비밀을 남기지 않는다.
	go io.Copy(io.Discard, p.Err)
	s.Notify = func(method string, params object) error {
		mu.Lock()
		defer mu.Unlock()
		_, e := p.In.Write(append(encoded(object{"method": method, "params": params}), '\n'))
		return e
	}
	s.Call = func(method string, params object) (object, error) {
		mu.Lock()
		defer mu.Unlock()
		id++
		request := object{"id": id, "method": method, "params": params}
		if _, e := p.In.Write(append(encoded(request), '\n')); e != nil {
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
					if !ok {
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
			return r.m, r.e
		case <-time.After(30 * time.Second):
			p.In.Close()
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
	r, e := s.Call("ctxhop/prepare", object{"contractVersion": 1, "requestNonce": requestNonce, "operation": operation, "home": o.Home, "cwd": o.Cwd, "offline": true, "members": descriptors})
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
	if e = validateProjection(r, requestNonce, operation, o, checkMembers, int64(p.PID)); e != nil {
		p.close()
		return nil, e
	}
	s.Members = members
	s.Options = o
	s.Operation = operation
	s.Projection = r
	s.bind()
	p.prepared = true
	return s, nil
}
func (s *session) bind() {
	s.Binding = object{}
	for _, k := range []string{"requestNonce", "processNonce", "snapshotId", "generation", "projectionDigest"} {
		s.Binding[k] = s.Projection[k]
	}
	s.Binding["operation"] = s.Operation
}
func (s *session) complete(observed dbView) error {
	if s.Projection["inputComplete"] == true {
		return nil
	}
	before := observed.Hashes
	current, e := dbHashes(text(s.Projection["stateDb"]))
	if e != nil {
		return e
	}
	if !bytes.Equal(encoded(before), encoded(current)) {
		return fail("engine_db_changed", "U-a 이후 DB/WAL 변경")
	}
	main := before[text(s.Projection["stateDb"])]
	if !hashRE.MatchString(main) {
		return fail("engine_db_unknown", "complete 전 DB 본문 부재")
	}
	var wal any
	w := before[text(s.Projection["stateDb"])+"-wal"]
	if w != "absent" {
		if !hashRE.MatchString(w) {
			return fail("engine_db_unknown", "complete 전 WAL hash 오류")
		}
		wal = w
	}
	params := object{}
	for k, v := range s.Binding {
		params[k] = v
	}
	params["dbObservation"] = object{"stateDb": s.Projection["stateDb"], "mainSha256": main, "walSha256": wal}
	r, e := s.Call("ctxhop/complete", params)
	if e != nil {
		return e
	}
	after, e := dbHashes(text(s.Projection["stateDb"]))
	if e != nil {
		return e
	}
	if !bytes.Equal(encoded(before), encoded(after)) {
		return fail("engine_db_changed", "complete 중 DB/WAL 변경")
	}
	oldGen, _ := integer(s.Projection["generation"])
	newGen, _ := integer(r["generation"])
	if newGen <= oldGen || text(r["processNonce"]) != text(s.Projection["processNonce"]) || text(r["snapshotId"]) != text(s.Projection["snapshotId"]) || r["inputComplete"] != true {
		return fail("prestart_binding", "최종 complete binding 오류")
	}
	pid, _ := integer(s.Projection["processId"])
	if e = validateProjection(r, text(s.Projection["requestNonce"]), s.Operation, s.Options, s.Members, pid); e != nil {
		return e
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
func validateProjection(r object, n, operation string, o options, members []member, pid int64) error {
	if !exact(r, "contractVersion", "requestNonce", "processId", "processNonce", "snapshotId", "generation", "engineVersion", "loaderContractId", "inputComplete", "home", "normalSqliteHome", "operationSqliteHome", "stateDb", "sqliteRedirect", "writeTargets", "projectConfig", "contexts", "authResolution", "policyResolution", "validity", "projectionDigest", "effects") {
		return fail("prestart_schema", "알 수 없는 prepare projection 구조")
	}
	version, ok := integer(r["contractVersion"])
	processID, pok := integer(r["processId"])
	gen, gok := integer(r["generation"])
	partial := r["inputComplete"] == false && len(members) == 0 && operation != "plan" && operation != "bootstrap"
	if !ok || version != 1 || !pok || processID != pid || !gok || gen < 1 || text(r["requestNonce"]) != n || text(r["processNonce"]) == "" || text(r["snapshotId"]) == "" || !hashRE.MatchString(text(r["projectionDigest"])) || text(r["loaderContractId"]) != loaderContractID || !versionAllowed(text(r["engineVersion"])) || r["inputComplete"] != true && !partial || r["sqliteRedirect"] != false {
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
	if !exact(effects, "applicationWrites", "networkRequests", "sqliteShmMayChange") || !wok || !nok || writes != 0 || network != 0 || (effects["sqliteShmMayChange"] != true && effects["sqliteShmMayChange"] != false) || partial && effects["sqliteShmMayChange"] != false || r["inputComplete"] == true && operation != "plan" && operation != "bootstrap" && effects["sqliteShmMayChange"] != true {
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
	targets := array(r["writeTargets"])
	kinds := map[string]bool{"state": false, "logs": false, "goals": false, "memories": false, "memoriesV2": false, "queue": false, "threadHistory": false}
	paths := map[string]bool{}
	if len(targets) != len(kinds) {
		return fail("prestart_targets", "DB write descriptor 누락")
	}
	for _, v := range targets {
		t := obj(v)
		kind, path := text(t["kind"]), text(t["path"])
		seen, known := kinds[kind]
		if !exact(t, "kind", "path") || !known || seen || !filepath.IsAbs(path) || !within(o.Home, path) || samePath(path, o.Home) || paths[strings.ToLower(filepath.Clean(path))] {
			return fail("prestart_targets", "DB write descriptor 오류")
		}
		if e := noReparse(path); e != nil {
			return e
		}
		if kind == "state" && !samePath(path, text(r["stateDb"])) {
			return fail("prestart_targets", "state descriptor 불일치")
		}
		kinds[kind] = true
		paths[strings.ToLower(filepath.Clean(path))] = true
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
func (s *session) activate() error {
	if s.Projection["inputComplete"] != true {
		return fail("prestart_incomplete", "complete 전 activate 금지")
	}
	for _, step := range []struct{ method, key string }{{"ctxhop/accept", "accepted"}, {"ctxhop/activate", "activated"}} {
		r, e := s.Call(step.method, s.Binding)
		if e != nil {
			return e
		}
		if r[step.key] != true {
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
