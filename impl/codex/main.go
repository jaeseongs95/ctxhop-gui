// ctxhop-codex는 protected engine의 승인된 새 대화 복원만 수행한다.
package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

var engineSHA256, normalEngineSHA256, loaderContractID string // 배포 빌드가 검증된 두 엔진에 결속한다.
const implementation = "ctxhop-codex-r45-v1"
const limit int64 = 1 << 30
const lineLimit = 16 << 20

var uuidRE = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var opRE = regexp.MustCompile(`^[0-9a-f]{32}$`)
var hashRE = regexp.MustCompile(`^[0-9a-f]{64}$`)
var fileIDRE = regexp.MustCompile(`^[0-9a-f]{24}$`)

type object = map[string]any
type failure struct{ Code, Message string }

func (f *failure) Error() string      { return f.Message }
func fail(code, message string) error { return &failure{code, message} }
func reason(err error) string {
	var f *failure
	if errors.As(err, &f) {
		return f.Code
	}
	return "io_error"
}
func digest(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func encoded(v any) []byte {
	b, e := json.Marshal(v)
	if e != nil {
		panic(e)
	}
	return b
}
func nonce() string {
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b)
}
func text(v any) string { s, _ := v.(string); return s }
func obj(v any) object  { m, _ := v.(map[string]any); return m }
func array(v any) []any { a, _ := v.([]any); return a }
func integer(v any) (int64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	i, e := n.Int64()
	return i, e == nil
}
func exact(m object, keys ...string) bool {
	if len(m) != len(keys) {
		return false
	}
	for _, k := range keys {
		if _, ok := m[k]; !ok {
			return false
		}
	}
	return true
}

// encoding/json의 마지막 중복 키 우선 동작을 신뢰 경계에서 허용하지 않는다.
func parseJSON(b []byte) (any, error) {
	if !utf8.Valid(b) {
		return nil, fail("invalid_json", "JSON UTF-8 오류")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var read func() (any, error)
	depth := 0
	read = func() (any, error) {
		depth++
		defer func() { depth-- }()
		if depth > 128 {
			return nil, fail("invalid_json", "JSON 깊이 한도 초과")
		}
		t, e := d.Token()
		if e != nil {
			return nil, e
		}
		if x, ok := t.(json.Delim); ok {
			switch x {
			case '{':
				m := object{}
				for d.More() {
					k, e := d.Token()
					if e != nil {
						return nil, e
					}
					s, ok := k.(string)
					if !ok {
						return nil, fail("invalid_json", "JSON 키 오류")
					}
					if _, ok := m[s]; ok {
						return nil, fail("invalid_json", "중복 JSON 키")
					}
					v, e := read()
					if e != nil {
						return nil, e
					}
					m[s] = v
				}
				_, e = d.Token()
				return m, e
			case '[':
				a := []any{}
				for d.More() {
					v, e := read()
					if e != nil {
						return nil, e
					}
					a = append(a, v)
				}
				_, e = d.Token()
				return a, e
			default:
				return nil, fail("invalid_json", "JSON 구분자 오류")
			}
		}
		return t, nil
	}
	v, e := read()
	if e != nil {
		return nil, fail("invalid_json", "JSON 구조가 올바르지 않습니다")
	}
	if _, e = d.Token(); e != io.EOF {
		return nil, fail("invalid_json", "JSON 뒤 데이터")
	}
	return v, nil
}
func readBounded(path string, max int64) ([]byte, error) {
	if e := noReparse(path); e != nil {
		return nil, e
	}
	f, e := os.Open(path)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	st, e := f.Stat()
	if e != nil {
		return nil, e
	}
	if !st.Mode().IsRegular() || st.Size() > max {
		return nil, fail("size_limit", "파일 크기/형식 오류")
	}
	b, e := io.ReadAll(io.LimitReader(f, max+1))
	if int64(len(b)) > max {
		return nil, fail("size_limit", "파일 크기 초과")
	}
	return b, e
}
func absolute(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fail("invalid_path", "절대 경로가 필요합니다")
	}
	p := filepath.Clean(path)
	if e := noReparse(p); e != nil {
		return "", e
	}
	return p, nil
}
func samePath(a, b string) bool { return strings.EqualFold(filepath.Clean(a), filepath.Clean(b)) }
func within(root, p string) bool {
	r, e := filepath.Rel(root, p)
	return e == nil && r != ".." && !strings.HasPrefix(r, ".."+string(os.PathSeparator)) && !filepath.IsAbs(r)
}

type options struct {
	Home, Archive, Cwd, Token, Run, Engine, NormalEngine string
	ApprovalEvidence                                     *approvalDescriptor
	RecoveryEvidence                                     *recoveryDescriptor
	RecordSHA256                                         string
}

func cli(args []string) (object, error) {
	if len(args) == 0 {
		return nil, fail("arguments", "plan/import/rollback/guard 명령이 필요합니다")
	}
	o := options{}
	f := flag.NewFlagSet(args[0], flag.ContinueOnError)
	f.SetOutput(io.Discard)
	f.StringVar(&o.Home, "home", "", "")
	f.StringVar(&o.Archive, "archive", "", "")
	f.StringVar(&o.Cwd, "cwd", "", "")
	f.StringVar(&o.Token, "token", "", "")
	f.StringVar(&o.Run, "run", "", "")
	f.StringVar(&o.Engine, "engine", "", "")
	f.StringVar(&o.NormalEngine, "normal-engine", "", "")
	f.StringVar(&o.RecordSHA256, "sha256", "", "")
	if e := f.Parse(args[1:]); e != nil || f.NArg() != 0 {
		return nil, fail("arguments", "잘못된 명령 인자")
	}
	var e error
	if args[0] == "recovery-list" || args[0] == "recovery-status" || args[0] == "recovery-resolve" || args[0] == "finalize" {
		allowed := map[string]bool{"home": true}
		if args[0] != "recovery-list" { allowed["run"] = true }
		if args[0] == "recovery-resolve" { allowed["sha256"] = true }
		bad := false; f.Visit(func(v *flag.Flag) { if !allowed[v.Name] { bad = true } })
		if bad || !filepath.IsAbs(o.Home) || args[0] != "recovery-list" && !opRE.MatchString(o.Run) || args[0] == "recovery-resolve" && !hashRE.MatchString(o.RecordSHA256) { return nil, fail("arguments", "복구 명령 인자 오류") }
		o.Home = filepath.Clean(o.Home)
		switch args[0] {
		case "recovery-list": rows, e := recoveryRecords(o.Home); return object{"records": rows}, e
		case "recovery-status": row, e := classifyRecoveryRecord(o.Home, o.Run); return object{"record": row}, e
		case "recovery-resolve": row, e := recoveryResolve(o.Home, o.Run, o.RecordSHA256); return object{"record": row}, e
		case "finalize": if _, e := finalizeLocal(o.Home, o.Run); e != nil { return nil, e }; row, e := classifyRecoveryRecord(o.Home, o.Run); return object{"record": row}, e
		}
	}
	o.Home, e = absolute(o.Home)
	if e != nil {
		return nil, e
	}
	st, e := os.Stat(o.Home)
	if e != nil || !st.IsDir() {
		return nil, fail("invalid_path", "대상 홈이 없습니다")
	}
	if args[0] == "guard" {
		if e := guard(nil); e != nil {
			return object{"status": "busy"}, e
		}
		return object{"status": "closed"}, nil
	}
	if args[0] == "rollback" {
		if !opRE.MatchString(o.Run) {
			return nil, fail("invalid_run", "작업 ID 오류")
		}
		return rollback(o)
	}
	if args[0] != "plan" && args[0] != "import" {
		return nil, fail("arguments", "알 수 없는 명령")
	}
	o.Cwd, e = absolute(o.Cwd)
	if e != nil {
		return nil, e
	}
	if st, e = os.Stat(o.Cwd); e != nil || !st.IsDir() {
		return nil, fail("invalid_path", "목표 폴더가 없습니다")
	}
	o.Archive, e = absolute(o.Archive)
	if e != nil {
		return nil, e
	}
	if args[0] == "plan" {
		return plan(o)
	}
	if !hashRE.MatchString(o.Token) || !opRE.MatchString(o.Run) {
		return nil, fail("arguments", "token/run 형식 오류")
	}
	return importArchive(o)
}
func main() {
	r, e := cli(os.Args[1:])
	if r == nil {
		r = object{}
	}
	if e != nil {
		r["error"] = e.Error()
		r["reasonCode"] = reason(e)
	}
	b, me := json.Marshal(r)
	if me != nil {
		b = []byte(`{"error":"출력 오류","reasonCode":"internal"}`)
		e = me
	}
	fmt.Println(string(b))
	if e != nil {
		os.Exit(1)
	}
}
