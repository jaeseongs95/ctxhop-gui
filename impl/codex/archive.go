package main

import (
	"archive/zip"
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// 배포 백엔드의 검증된 구조 사본. archive SQL은 실행하지 않는다.
//
//go:embed schema.json
var schemaBytes []byte

//go:embed columns.json
var columnsBytes []byte
var trustedSchema = mustObject(schemaBytes)
var columns = mustObject(columnsBytes)

func mustObject(b []byte) object {
	v, e := parseJSON(b)
	if e != nil {
		panic(e)
	}
	return obj(v)
}

type member struct {
	ID      string   `json:"id"`
	Parent  *string  `json:"parent"`
	Path    string   `json:"path"`
	Size    int64    `json:"size"`
	SHA256  string   `json:"sha256"`
	Data    object   `json:"-"`
	Raw     []byte   `json:"-"`
	Header  object   `json:"-"`
	Records []object `json:"-"`
}
type family struct {
	Members                   []member
	Edges                     []any
	ArchiveSHA, EngineVersion string
	Archived                  bool
}

func rowValidate(v any, table string) error {
	m := obj(v)
	cs := obj(columns[table])
	if m == nil || len(m) != len(cs) {
		return fail("archive_row", "DB 열 목록 오류")
	}
	for k, c := range cs {
		v, ok := m[k]
		if !ok {
			return fail("archive_row", "DB 열 누락")
		}
		spec := array(c)
		required, _ := integer(spec[1])
		if v == nil {
			if required != 0 {
				return fail("archive_row", "DB 필수 값 누락")
			}
			continue
		}
		kind := text(spec[0])
		switch kind {
		case "TEXT", "VARCHAR":
			if _, ok := v.(string); !ok {
				return fail("archive_row", "DB 문자열 오류")
			}
		case "INTEGER", "BIGINT", "BOOLEAN":
			if _, ok := integer(v); !ok {
				return fail("archive_row", "DB 정수 오류")
			}
		}
		switch v.(type) {
		case string, json.Number:
		default:
			return fail("archive_row", "DB 값 형식 오류")
		}
	}
	return nil
}
func records(raw []byte, id string, parents []string) ([]object, error) {
	if len(raw) == 0 || int64(len(raw)) > limit || raw[len(raw)-1] != '\n' {
		return nil, fail("archive_rollout", "세션이 비었거나 불완전합니다")
	}
	lines := bytes.Split(raw[:len(raw)-1], []byte{'\n'})
	result := make([]object, 0, len(lines))
	for _, line := range lines {
		if len(line) == 0 || len(line) > lineLimit || !utf8.Valid(line) {
			return nil, fail("archive_rollout", "세션 줄 크기/인코딩 오류")
		}
		v, e := parseJSON(line)
		if e != nil {
			return nil, e
		}
		m := obj(v)
		if m == nil || obj(m["payload"]) == nil {
			return nil, fail("archive_rollout", "세션 레코드 구조 오류")
		}
		result = append(result, m)
	}
	h := obj(result[0]["payload"])
	if text(result[0]["type"]) != "session_meta" || text(h["id"]) != id {
		return nil, fail("archive_rollout", "세션 헤더 ID 오류")
	}
	session, e := canonicalRolloutSessionID(h)
	if e != nil {
		return nil, e
	}
	if session != id {
		found := false
		for _, p := range parents {
			found = found || session == p
		}
		if !found {
			return nil, fail("archive_rollout", "세션 헤더 조상 오류")
		}
	}
	return result, nil
}

// SessionMetaLine's canonical decoder supplies id only when session_id is
// absent. Keep original archive bytes/header intact; null/empty are not absent.
func canonicalRolloutSessionID(header object) (string, error) {
	value, exists := header["session_id"]
	if !exists {
		value = header["id"]
	}
	id, ok := value.(string)
	if !ok || !uuidRE.MatchString(id) {
		return "", fail("archive_rollout", "세션 헤더 root SessionId 형식 오류")
	}
	return id, nil
}
func readArchive(path string) (*family, error) {
	raw, e := readBounded(path, limit)
	if e != nil {
		return nil, e
	}
	z, e := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if e != nil {
		return nil, fail("archive_zip", "ZIP 읽기 실패")
	}
	if len(z.File) > 2002 {
		return nil, fail("size_limit", "ZIP 항목 초과")
	}
	files := map[string][]byte{}
	var total uint64
	for _, f := range z.File {
		if _, ok := files[f.Name]; ok {
			return nil, fail("archive_zip", "중복 ZIP 이름")
		}
		if f.Mode()&(^f.Mode().Perm()) != 0 && !f.Mode().IsRegular() {
			return nil, fail("archive_zip", "ZIP 파일 형식 오류")
		}
		total += f.UncompressedSize64
		if total > uint64(limit) || f.UncompressedSize64 > uint64(limit) || (f.Name == "manifest.json" && f.UncompressedSize64 > 1<<20) {
			return nil, fail("size_limit", "ZIP 해제 크기 초과")
		}
		r, e := f.Open()
		if e != nil {
			return nil, e
		}
		b, e := io.ReadAll(io.LimitReader(r, int64(f.UncompressedSize64)+1))
		ce := r.Close()
		if e != nil || ce != nil || uint64(len(b)) != f.UncompressedSize64 {
			return nil, fail("archive_zip", "ZIP 내용/CRC 검증 실패")
		}
		files[f.Name] = b
	}
	mv, e := parseJSON(files["manifest.json"])
	if e != nil {
		return nil, e
	}
	manifest := obj(mv)
	if !exact(manifest, "format", "schema", "engineVersion", "hashes") {
		return nil, fail("archive_manifest", "manifest 키 오류")
	}
	format, ok := integer(manifest["format"])
	if !ok || (format != 1 && format != 2) {
		return nil, fail("archive_manifest", "보관 형식 오류")
	}
	hashes := obj(manifest["hashes"])
	if len(hashes) != len(files)-1 {
		return nil, fail("archive_hash", "파일 해시 목록 오류")
	}
	for k, b := range files {
		if k != "manifest.json" && text(hashes[k]) != digest(b) {
			return nil, fail("archive_hash", "파일 해시 불일치")
		}
	}
	if !bytes.Equal(encoded(manifest["schema"]), encoded(trustedSchema)) {
		return nil, fail("archive_schema", "보관 DB 구조가 지원 구조와 다릅니다")
	}
	ver := text(manifest["engineVersion"])
	if ver != "0.158.0-alpha.2" && ver != "0.158.0-alpha.2.1" {
		return nil, fail("archive_version", "보관 원본 버전 오류")
	}
	dv, e := parseJSON(files["data.json"])
	if e != nil {
		return nil, e
	}
	data := obj(dv)
	f := &family{ArchiveSHA: digest(raw), EngineVersion: ver}
	var datas []any
	var names []string
	if format == 1 {
		if len(files) != 3 {
			return nil, fail("archive_manifest", "형식1 항목 오류")
		}
		datas = []any{data}
		names = []string{"rollout.jsonl"}
		f.Edges = []any{}
	} else {
		if !exact(data, "members", "edges") {
			return nil, fail("archive_manifest", "가족 자료 키 오류")
		}
		datas = array(data["members"])
		f.Edges = array(data["edges"])
		if f.Edges == nil {
			return nil, fail("archive_edges", "연결 목록 오류")
		}
		for i := range datas {
			names = append(names, fmt.Sprintf("rollouts/%04d.jsonl", i))
		}
		if len(files) != len(datas)+2 {
			return nil, fail("archive_manifest", "형식2 항목 오류")
		}
	}
	if len(datas) < 1 || len(datas) > 2000 {
		return nil, fail("archive_members", "구성원 수 오류")
	}
	ids := map[string]bool{}
	parents := map[string]string{}
	for i, d := range datas {
		m := obj(d)
		if !exact(m, "thread", "history", "dynamicTools") || array(m["dynamicTools"]) == nil {
			return nil, fail("archive_member", "구성원 자료 오류")
		}
		if e := rowValidate(m["thread"], "threads"); e != nil {
			return nil, e
		}
		id := text(obj(m["thread"])["id"])
		if !uuidRE.MatchString(id) || ids[id] {
			return nil, fail("archive_id", "UUID 또는 중복 구성원 오류")
		}
		ids[id] = true
		b, ok := files[names[i]]
		if !ok {
			return nil, fail("archive_manifest", "롤아웃 누락")
		}
		f.Members = append(f.Members, member{ID: id, Raw: b, Size: int64(len(b)), SHA256: digest(b), Data: m})
	}
	root := f.Members[0].ID
	for _, v := range f.Edges {
		edge := obj(v)
		if !exact(edge, "parent_thread_id", "child_thread_id", "status") {
			return nil, fail("archive_edges", "연결 키 오류")
		}
		p, c := text(edge["parent_thread_id"]), text(edge["child_thread_id"])
		if !ids[p] || !ids[c] || c == root || parents[c] != "" || text(edge["status"]) == "" {
			return nil, fail("archive_edges", "연결/중복 오류")
		}
		parents[c] = p
	}
	if len(parents) != len(f.Members)-1 {
		return nil, fail("archive_edges", "가족 연결 누락")
	}
	for i := range f.Members {
		m := &f.Members[i]
		row := obj(m.Data["thread"])
		var chain []string
		node := m.ID
		seen := map[string]bool{node: true}
		for node != root {
			node = parents[node]
			if node == "" || seen[node] {
				return nil, fail("archive_edges", "연결 순환 오류")
			}
			seen[node] = true
			chain = append(chain, node)
		}
		if i > 0 {
			p := parents[m.ID]
			m.Parent = &p
		}
		rs, e := records(m.Raw, m.ID, chain)
		if e != nil {
			return nil, e
		}
		m.Records = rs
		m.Header = obj(rs[0]["payload"])
		if !filepath.IsAbs(text(row["cwd"])) || !samePath(text(m.Header["cwd"]), text(row["cwd"])) || len(text(m.Header["cli_version"])) == 0 || len(text(m.Header["cli_version"])) > 200 {
			return nil, fail("archive_member", "헤더 경로/버전 오류")
		}
		mode := text(row["history_mode"])
		if mode != "legacy" && mode != "paginated" {
			return nil, fail("archive_history", "이력 형식 오류")
		}
		if i > 0 && (!strings.HasPrefix(text(row["source"]), `{"subagent":`) || text(m.Header["parent_thread_id"]) != *m.Parent) {
			return nil, fail("archive_edges", "하위 헤더/연결 오류")
		}
		hs := obj(m.Data["history"])
		if !exact(hs, "thread_turns", "thread_items", "thread_history_projection_state", "thread_realtime_items") {
			return nil, fail("archive_history", "이력 표 목록 오류")
		}
		for table, v := range hs {
			rows := array(v)
			if rows == nil || len(rows) > 1000000 {
				return nil, fail("archive_history", "이력 행 목록 오류")
			}
			for _, r := range rows {
				if e := rowValidate(r, table); e != nil {
					return nil, e
				}
				o := obj(r)
				if text(o["thread_id"]) != m.ID {
					return nil, fail("archive_history", "다른 구성원 이력")
				}
				for _, k := range []string{"rollout_byte_offset", "rollout_end_byte_offset", "next_rollout_byte_offset"} {
					if v, ok := o[k]; ok && v != nil {
						n, valid := integer(v)
						if !valid || n < 0 || n > int64(len(m.Raw)) {
							return nil, fail("archive_history", "이력 위치 범위 오류")
						}
					}
				}
			}
		}
	}
	n, _ := integer(obj(f.Members[0].Data["thread"])["archived"])
	f.Archived = n != 0
	return f, nil
}

var rolloutNameRE = regexp.MustCompile(`^rollout-\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-([0-9a-f-]{36})(_[0-9a-f-]{36})?\.jsonl$`)

func versionAllowed(s string) bool {
	r := regexp.MustCompile(`^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$`)
	m := r.FindStringSubmatch(s)
	if m == nil {
		return false
	}
	var a, b, c uint64
	if _, e := fmt.Sscanf(strings.Join(m[1:4], "."), "%d.%d.%d", &a, &b, &c); e != nil {
		return false
	}
	return a > 0 || b > 156 || (b == 156 && c >= 0)
}
func support(f *family, home string) error {
	if strings.HasPrefix(text(obj(f.Members[0].Data["thread"])["source"]), `{"subagent":`) {
		return fail("subagent_root", "최상위가 하위 에이전트입니다")
	}
	ids := map[string]bool{}
	for _, m := range f.Members {
		ids[m.ID] = true
	}
	for _, edge := range f.Edges {
		e := obj(edge)
		if text(e["status"]) != "open" {
			return fail("closed_edge", "닫힌 연결")
		}
		if text(e["parent_thread_id"]) != f.Members[0].ID {
			return fail("grandchild", "손자 연결")
		}
	}
	for i := range f.Members {
		m := &f.Members[i]
		r := obj(m.Data["thread"])
		created, ok := integer(r["created_at"])
		if !ok || created < 1577836800 || created > time.Now().Add(24*time.Hour).Unix() {
			return fail("created_at", "대화 생성 시각 범위 오류")
		}
		title := text(r["name"])
		if title == "" {
			title = text(r["title"])
		}
		if utf8.RuneCountInString(title) > 1000 {
			return fail("bad_title", "제목이 너무 깁니다")
		}
		for _, c := range title {
			if unicode.IsControl(c) {
				return fail("bad_title", "제목 제어 문자")
			}
		}
		ar, _ := integer(r["archived"])
		if (ar != 0) != f.Archived {
			return fail("mixed_archived", "구성원 보관 상태가 다릅니다")
		}
		orig := text(r["rollout_path"])
		match := rolloutNameRE.FindStringSubmatch(filepath.Base(orig))
		if match == nil || match[1] != m.ID {
			return fail("bad_rollout_path", "롤아웃 이름 오류")
		}
		if match[2] != "" {
			return fail("revert_rollout", "되돌린 롤아웃")
		}
		settings := m.Header
		ownSettings := false
		for _, rec := range m.Records {
			p := obj(rec["payload"])
			if text(rec["type"]) == "event_msg" && text(p["type"]) == "thread_settings_applied" && text(p["thread_id"]) == m.ID {
				ownSettings = true
				settings = obj(p["thread_settings"])
				if settings == nil {
					return fail("archive_rollout", "설정 구조 오류")
				}
			}
		}
		roots, exists := settings["runtime_workspace_roots"]
		if !exists && !ownSettings {
			roots = []any{text(m.Header["cwd"])}
		}
		a := array(roots)
		if len(a) != 1 || text(a[0]) != text(settings["cwd"]) {
			return fail("extra_roots", "추가 작업 루트 또는 빈 작업 루트")
		}
		if hb := m.Header["history_base"]; hb != nil {
			h := obj(hb)
			if h == nil || !ids[text(h["thread_id"])] {
				return fail("external_history", "묶음 밖 이력")
			}
		}
		if v := multiAgentVersion(*m); v != "" && v != "v1" && v != "v2" {
			return fail("multi_agent_version", "알 수 없는 에이전트 버전")
		}
		utc := time.Unix(created, 0).UTC()
		m.Path = filepath.Join(home, "sessions", utc.Format("2006"), utc.Format("01"), utc.Format("02"), "rollout-"+utc.Format("2006-01-02T15-04-05")+"-"+m.ID+".jsonl")
	}
	return nil
}
func multiAgentVersion(m member) string {
	for i := len(m.Records) - 1; i >= 0; i-- {
		r := m.Records[i]
		p := obj(r["payload"])
		if text(r["type"]) == "session_meta" && text(p["id"]) == m.ID && p["multi_agent_version"] != nil {
			return text(p["multi_agent_version"])
		}
	}
	for i := len(m.Records) - 1; i >= 0; i-- {
		r := m.Records[i]
		p := obj(r["payload"])
		switch text(r["type"]) {
		case "turn_context":
		case "compacted":
			p = obj(p["resume_metadata"])
		default:
			continue
		}
		if p["multi_agent_version"] != nil {
			return text(p["multi_agent_version"])
		}
	}
	return ""
}
