//go:build windows

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

var kernel = syscall.NewLazyDLL("kernel32.dll")
var assignOwnedJob = func(job, handle syscall.Handle) error {
	r, _, e := proc("AssignProcessToJobObject").Call(uintptr(job), uintptr(handle))
	if r == 0 {
		return e
	}
	return nil
}

func proc(name string) *syscall.LazyProc { return kernel.NewProc(name) }
func noReparse(path string) error {
	p := filepath.Clean(path)
	for {
		u, e := syscall.UTF16PtrFromString(p)
		if e != nil {
			return e
		}
		attrs, e := syscall.GetFileAttributes(u)
		if e != nil {
			if e != syscall.ERROR_FILE_NOT_FOUND && e != syscall.ERROR_PATH_NOT_FOUND {
				return e
			}
		} else if attrs&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return fail("reparse", "링크/연결 경로")
		}
		parent := filepath.Dir(p)
		if parent == p {
			break
		}
		p = parent
	}
	return nil
}
func moveFile(src, dst string, replace bool) error {
	if e := noReparse(src); e != nil {
		return e
	}
	if e := noReparse(dst); e != nil {
		return e
	}
	a, e := syscall.UTF16PtrFromString(src)
	if e != nil {
		return e
	}
	b, e := syscall.UTF16PtrFromString(dst)
	if e != nil {
		return e
	}
	flags := uintptr(8)
	if replace {
		flags |= 1
	}
	r, _, e := proc("MoveFileExW").Call(uintptr(unsafe.Pointer(a)), uintptr(unsafe.Pointer(b)), flags)
	if r == 0 {
		return e
	}
	return nil
}
func systemDirectory() (string, error) {
	b := make([]uint16, 32768)
	r, _, e := proc("GetSystemDirectoryW").Call(uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)))
	if r == 0 || r >= uintptr(len(b)) {
		return "", e
	}
	return syscall.UTF16ToString(b[:r]), nil
}

type process struct {
	job, handle      syscall.Handle
	PID              uint32
	Created          uint64
	Image            string
	In, Out, Err     *os.File
	prepared, closed bool
	ImageLocks       []*os.File
}

func lockImage(path string) ([]*os.File, error) {
	locks := []*os.File{}
	closeAll := func() {
		for _, f := range locks {
			f.Close()
		}
	}
	for p := path; ; p = filepath.Dir(p) {
		if e := noReparse(p); e != nil {
			closeAll()
			return nil, e
		}
		u, e := syscall.UTF16PtrFromString(p)
		if e != nil {
			closeAll()
			return nil, e
		}
		access := uint32(0x80)
		share := uint32(3)
		flags := uint32(0x02200000)
		if p == path {
			access = 0x80000000
			share = 1
			flags = 0x00200000
		}
		h, e := syscall.CreateFile(u, access, share, nil, syscall.OPEN_EXISTING, flags, 0)
		if e != nil {
			closeAll()
			return nil, e
		}
		f := os.NewFile(uintptr(h), p)
		locks = append(locks, f)
		var info syscall.ByHandleFileInformation
		if e = syscall.GetFileInformationByHandle(h, &info); e != nil || info.FileAttributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			closeAll()
			return nil, fail("engine_identity", "image 경로 handle/reparse 오류")
		}
		if filepath.Dir(p) == p {
			break
		}
	}
	return locks, nil
}

func incarnation(h syscall.Handle) (uint64, error) {
	var c, x, k, u syscall.Filetime
	if e := syscall.GetProcessTimes(h, &c, &x, &k, &u); e != nil {
		return 0, e
	}
	return uint64(c.HighDateTime)<<32 | uint64(c.LowDateTime), nil
}
func processImage(h syscall.Handle) (string, error) {
	b := make([]uint16, 32768)
	n := uint32(len(b))
	r, _, e := proc("QueryFullProcessImageNameW").Call(uintptr(h), 0, uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(&n)))
	if r == 0 {
		return "", e
	}
	return syscall.UTF16ToString(b[:n]), nil
}
func (p *process) provePrepared() error {
	if p == nil || !p.prepared || p.closed {
		return fail("guard_binding", "prepared PID 상태 불일치")
	}
	var yes int32
	r, _, e := proc("IsProcessInJob").Call(uintptr(p.handle), uintptr(p.job), uintptr(unsafe.Pointer(&yes)))
	if r == 0 || yes == 0 {
		return fail("guard_binding", fmt.Sprintf("owned Job 불일치: %v", e))
	}
	c, e := incarnation(p.handle)
	if e != nil || c != p.Created {
		return fail("guard_binding", "PID incarnation 불일치")
	}
	image, e := processImage(p.handle)
	if e != nil || !samePath(image, p.Image) {
		return fail("guard_binding", "PID image 불일치")
	}
	var exit uint32
	if e := syscall.GetExitCodeProcess(p.handle, &exit); e != nil || exit != 259 {
		return fail("guard_binding", "프로세스 조회 실패")
	}
	return nil
}
func startProcess(image, dir string, env []string) (*process, error) {
	if runtime.GOARCH != "amd64" {
		return nil, fail("platform", "Windows amd64가 필요합니다")
	}
	if e := noReparse(image); e != nil {
		return nil, e
	}
	if e := noReparse(dir); e != nil {
		return nil, e
	}
	jr, _, e := proc("CreateJobObjectW").Call(0, 0)
	if jr == 0 {
		return nil, e
	}
	job := syscall.Handle(jr)
	success := false
	defer func() {
		if !success {
			syscall.CloseHandle(job)
		}
	}()
	lim := make([]byte, 144)
	binary.LittleEndian.PutUint32(lim[16:], 0x2000)
	r, _, e := proc("SetInformationJobObject").Call(jr, 9, uintptr(unsafe.Pointer(&lim[0])), uintptr(len(lim)))
	if r == 0 {
		return nil, e
	}
	inR, inW, e := os.Pipe()
	if e != nil {
		return nil, e
	}
	outR, outW, e := os.Pipe()
	if e != nil {
		inR.Close()
		inW.Close()
		return nil, e
	}
	errR, errW, e := os.Pipe()
	if e != nil {
		inR.Close()
		inW.Close()
		outR.Close()
		outW.Close()
		return nil, e
	}
	files := []*os.File{inR, inW, outR, outW, errR, errW}
	defer func() {
		if !success {
			for _, f := range files {
				f.Close()
			}
		}
	}()
	handles := []syscall.Handle{}
	current := syscall.Handle(^uintptr(0))
	for _, f := range []*os.File{inR, outW, errW} {
		var h syscall.Handle
		if e = syscall.DuplicateHandle(current, syscall.Handle(f.Fd()), current, &h, 0, true, syscall.DUPLICATE_SAME_ACCESS); e != nil {
			return nil, e
		}
		handles = append(handles, h)
	}
	defer func() {
		for _, h := range handles {
			syscall.CloseHandle(h)
		}
	}()
	var size uintptr
	proc("InitializeProcThreadAttributeList").Call(0, 1, 0, uintptr(unsafe.Pointer(&size)))
	if size == 0 || size > 1<<20 {
		return nil, fail("job_launch", "attribute list 크기 오류")
	}
	attrs := make([]byte, size)
	r, _, e = proc("InitializeProcThreadAttributeList").Call(uintptr(unsafe.Pointer(&attrs[0])), 1, 0, uintptr(unsafe.Pointer(&size)))
	if r == 0 {
		return nil, e
	}
	defer proc("DeleteProcThreadAttributeList").Call(uintptr(unsafe.Pointer(&attrs[0])))
	r, _, e = proc("UpdateProcThreadAttribute").Call(uintptr(unsafe.Pointer(&attrs[0])), 0, 0x20002, uintptr(unsafe.Pointer(&handles[0])), uintptr(len(handles))*unsafe.Sizeof(handles[0]), 0, 0)
	if r == 0 {
		return nil, e
	}
	type startupEx struct {
		syscall.StartupInfo
		Attributes uintptr
	}
	si := startupEx{}
	si.Cb = uint32(unsafe.Sizeof(si))
	si.Flags = syscall.STARTF_USESTDHANDLES
	si.StdInput = handles[0]
	si.StdOutput = handles[1]
	si.StdErr = handles[2]
	si.Attributes = uintptr(unsafe.Pointer(&attrs[0]))
	var pi syscall.ProcessInformation
	application, e := syscall.UTF16PtrFromString(image)
	if e != nil {
		return nil, e
	}
	command, e := syscall.UTF16PtrFromString(syscall.EscapeArg(image))
	if e != nil {
		return nil, e
	}
	cwd, e := syscall.UTF16PtrFromString(dir)
	if e != nil {
		return nil, e
	}
	sort.Slice(env, func(i, j int) bool { return strings.ToUpper(env[i]) < strings.ToUpper(env[j]) })
	block := utf16.Encode([]rune(strings.Join(env, "\x00") + "\x00\x00"))
	r, _, e = proc("CreateProcessW").Call(uintptr(unsafe.Pointer(application)), uintptr(unsafe.Pointer(command)), 0, 0, 1, 0x08080404, uintptr(unsafe.Pointer(&block[0])), uintptr(unsafe.Pointer(cwd)), uintptr(unsafe.Pointer(&si)), uintptr(unsafe.Pointer(&pi)))
	runtime.KeepAlive(attrs)
	runtime.KeepAlive(block)
	if r == 0 {
		return nil, e
	}
	defer syscall.CloseHandle(pi.Thread)
	launched := false
	defer func() {
		if !launched {
			syscall.TerminateProcess(pi.Process, 1)
			syscall.WaitForSingleObject(pi.Process, 10000)
			syscall.CloseHandle(pi.Process)
		}
	}()
	e = assignOwnedJob(job, pi.Process)
	if e != nil {
		return nil, fail("job_assignment", "중첩 Job 할당 실패: "+e.Error())
	}
	created, e := incarnation(pi.Process)
	if e != nil {
		return nil, e
	}
	actual, e := processImage(pi.Process)
	if e != nil || !samePath(image, actual) {
		return nil, fail("engine_identity", "시작 image 불일치")
	}
	r, _, e = proc("ResumeThread").Call(uintptr(pi.Thread))
	if r == uintptr(0xffffffff) {
		return nil, e
	}
	inR.Close()
	outW.Close()
	errW.Close()
	success = true
	launched = true
	return &process{job: job, handle: pi.Process, PID: pi.ProcessId, Created: created, Image: actual, In: inW, Out: outR, Err: errR}, nil
}
func (p *process) active() (uint32, error) {
	b := make([]byte, 48)
	r, _, e := proc("QueryInformationJobObject").Call(uintptr(p.job), 1, uintptr(unsafe.Pointer(&b[0])), 48, 0)
	if r == 0 {
		return 0, e
	}
	return binary.LittleEndian.Uint32(b[40:]), nil
}
func (p *process) close() error {
	if p == nil || p.closed {
		return nil
	}
	p.In.Close()
	deadline := time.Now().Add(10 * time.Second)
	terminated := false
	for {
		n, e := p.active()
		if e != nil {
			return e
		}
		if n == 0 {
			break
		}
		if time.Now().After(deadline) {
			if terminated {
				return fail("job_active", "소유 Job이 비지 않았습니다")
			}
			r, _, e := proc("TerminateJobObject").Call(uintptr(p.job), 1)
			if r == 0 {
				return e
			}
			terminated = true
			deadline = time.Now().Add(10 * time.Second)
		}
		time.Sleep(20 * time.Millisecond)
	}
	p.Out.Close()
	p.Err.Close()
	syscall.CloseHandle(p.handle)
	syscall.CloseHandle(p.job)
	p.closed = true
	for _, f := range p.ImageLocks {
		f.Close()
	}
	return nil
}
func guard(p *process) error {
	excluded := uint32(0)
	if p != nil {
		if e := p.provePrepared(); e != nil {
			return e
		}
		excluded = p.PID
	}
	dir, e := systemDirectory()
	if e != nil {
		return e
	}
	shell := filepath.Join(dir, "WindowsPowerShell", "v1.0", "powershell.exe")
	script := fmt.Sprintf(`$ErrorActionPreference='Stop'; $all=@(Get-CimInstance Win32_Process); if (@($all | Where-Object { $_.Name -eq 'node.exe' -and -not $_.CommandLine }).Count) { exit 3 }; $writers=@($all | Where-Object { $_.ProcessId -ne %d -and ($_.Name -match '^(?i)(codex|ctxhop-codex-engine|codex-app|codex-code-mode-host|code-mode-host|ChatGPT|Code|Cursor|Windsurf)\.exe$' -or ($_.Name -eq 'node.exe' -and $_.CommandLine -match '(?i)(@openai[\\/]codex|[\\/]codex[\\/]bin[\\/]|codex.*app-server)')) }); if ($writers.Count) { exit 2 }; exit 0`, excluded)
	u := utf16.Encode([]rune(script))
	b := make([]byte, len(u)*2)
	for i, v := range u {
		binary.LittleEndian.PutUint16(b[i*2:], v)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, shell, "-NoProfile", "-NonInteractive", "-EncodedCommand", base64.StdEncoding.EncodeToString(b))
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	cmd.Stdout = ioDiscard{}
	cmd.Stderr = ioDiscard{}
	if e := cmd.Run(); e != nil {
		return fail("engine_open", "Codex 앱/CLI/IDE 종료 여부를 확인할 수 없거나 열려 있습니다")
	}
	return nil
}

type ioDiscard struct{}

func (ioDiscard) Write(b []byte) (int, error) { return len(b), nil }

type dbView struct {
	IDs         map[string]bool
	Edges       []object
	Count       int
	Hashes      map[string]string
	Acquisition *dbAcquisition
	Observation object
}

func checkDB(home, statePath string, members []member, allowMissing bool) (dbView, error) {
	return checkDBAcquisition(home, statePath, members, allowMissing, false)
}
func checkDBPrepared(home, statePath string, members []member, allowMissing bool) (dbView, error) {
	return checkDBAcquisition(home, statePath, members, allowMissing, true)
}
func checkDBAcquisition(home, statePath string, members []member, allowMissing, keep bool) (v dbView, retErr error) {
	v = dbView{IDs: map[string]bool{}}
	if !samePath(statePath, filepath.Join(home, "state_5.sqlite")) {
		return v, fail("engine_db_unknown", "실제 state descriptor 경로 오류")
	}
	if e := noReparse(statePath); e != nil {
		return v, e
	}
	matches, e := filepath.Glob(filepath.Join(home, "state_*.sqlite"))
	if e != nil {
		return v, e
	}
	for _, p := range matches {
		if !samePath(p, statePath) {
			return v, fail("engine_db_unknown", "다른 state DB가 있습니다")
		}
	}
	_, e = os.Stat(statePath)
	if os.IsNotExist(e) && allowMissing {
		return v, nil
	}
	if e != nil {
		return v, fail("engine_db_unknown", "state DB가 없거나 접근할 수 없습니다")
	}
	s, e := acquireSnapshot(statePath, filepath.Join(os.TempDir(), "ctxhop-acquisition-"+nonce()), limit, nil, nil)
	if e != nil {
		return v, fail("engine_db_unknown", "원본 raw acquisition 실패")
	}
	defer func() {
		if retErr != nil || !keep {
			retErr = errors.Join(retErr, s.Close(true))
		}
	}()
	privatePath := filepath.Join(s.Private, "state_5.sqlite")
	headerFile, e := os.Open(privatePath)
	if e != nil {
		return v, e
	}
	header := make([]byte, 100)
	_, e = io.ReadFull(headerFile, header)
	e = errors.Join(e, headerFile.Close())
	if e != nil || !bytes.Equal(header[:16], []byte("SQLite format 3\x00")) || (header[18] != 1 && header[18] != 2) || header[18] != header[19] {
		return v, fail("engine_db_unknown", "DB 파일 header 구조 불명")
	}
	dir, e := systemDirectory()
	if e != nil {
		return v, e
	}
	dll, e := syscall.LoadDLL(filepath.Join(dir, "winsqlite3.dll"))
	if e != nil {
		return v, fail("engine_db_unknown", "readonly SQLite를 사용할 수 없습니다")
	}
	defer dll.Release()
	funcs := map[string]*syscall.Proc{}
	for _, name := range []string{"sqlite3_open_v2", "sqlite3_close", "sqlite3_prepare_v2", "sqlite3_step", "sqlite3_finalize", "sqlite3_column_text", "sqlite3_column_count", "sqlite3_column_bytes"} {
		p, e := dll.FindProc(name)
		if e != nil {
			return v, e
		}
		funcs[name] = p
	}
	var db uintptr
	uri := url.URL{Scheme: "file", Path: "/" + filepath.ToSlash(privatePath), RawQuery: "mode=ro"}
	name := append([]byte(uri.String()), 0)
	r, _, _ := funcs["sqlite3_open_v2"].Call(uintptr(unsafe.Pointer(&name[0])), uintptr(unsafe.Pointer(&db)), 0x41, 0)
	if r != 0 {
		if db != 0 {
			funcs["sqlite3_close"].Call(db)
		}
		return v, fail("engine_db_unknown", "state DB readonly 열기 실패")
	}
	var inspectErr error
	query := func(sql string) (rows [][]string, retErr error) {
		buf := append([]byte(sql), 0)
		var stmt uintptr
		r, _, _ := funcs["sqlite3_prepare_v2"].Call(db, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)-1), uintptr(unsafe.Pointer(&stmt)), 0)
		if r != 0 {
			return nil, fail("engine_db_unknown", "readonly SQL 구조 검사 실패")
		}
		defer func() {
			rc, _, _ := funcs["sqlite3_finalize"].Call(stmt)
			if rc != 0 {
				retErr = errors.Join(retErr, fail("engine_db_unknown", "SQL statement 종료 실패"))
			}
		}()
		rows = [][]string{}
		for {
			r, _, _ := funcs["sqlite3_step"].Call(stmt)
			if r == 101 {
				return rows, nil
			}
			if r != 100 {
				return nil, fail("engine_db_unknown", "readonly SQL 읽기 실패")
			}
			if len(rows) >= 1000000 {
				return nil, fail("engine_db_unknown", "DB 행 한도")
			}
			n, _, _ := funcs["sqlite3_column_count"].Call(stmt)
			row := []string{}
			for i := uintptr(0); i < n; i++ {
				p, _, _ := funcs["sqlite3_column_text"].Call(stmt, i)
				if p == 0 {
					row = append(row, "")
					continue
				}
				length, _, _ := funcs["sqlite3_column_bytes"].Call(stmt, i)
				if length > lineLimit {
					return nil, fail("engine_db_unknown", "DB 값 크기 초과")
				}
				b := make([]byte, length)
				if length > 0 {
					proc("RtlMoveMemory").Call(uintptr(unsafe.Pointer(&b[0])), p, length)
					runtime.KeepAlive(b)
				}
				row = append(row, string(b))
			}
			rows = append(rows, row)
		}
	}
	inspectErr = func() error {
		if _, e := query("PRAGMA query_only=1"); e != nil {
			return e
		}
		if _, e := query("BEGIN"); e != nil {
			return e
		}
		check, e := query("PRAGMA quick_check")
		if e != nil || len(check) != 1 || check[0][0] != "ok" {
			return fail("engine_db_unknown", "state DB integrity 오류")
		}
		for _, table := range []string{"threads", "thread_spawn_edges"} {
			cols, e := query("PRAGMA table_info(" + table + ")")
			if e != nil {
				return e
			}
			got := map[string][]string{}
			for _, c := range cols {
				if len(c) != 6 {
					return fail("engine_db_unknown", "DB 열 descriptor 오류")
				}
				got[c[1]] = c
			}
			if table == "threads" {
				c := got["id"]
				if len(c) != 6 || strings.ToUpper(c[2]) != "TEXT" || c[5] != "1" {
					return fail("engine_db_unknown", "threads id 구조 오류")
				}
			} else {
				if len(got) != 3 {
					return fail("engine_db_unknown", "edge 구조 불명")
				}
				for _, key := range []string{"parent_thread_id", "child_thread_id", "status"} {
					c := got[key]
					if len(c) != 6 || strings.ToUpper(c[2]) != "TEXT" || c[3] != "1" {
						return fail("engine_db_unknown", "edge 열 구조 불명")
					}
				}
				if got["child_thread_id"][5] != "1" || got["parent_thread_id"][5] != "0" || got["status"][5] != "0" {
					return fail("engine_db_unknown", "edge 기본 키 구조 불명")
				}
			}
		}
		rows, e := query("SELECT id FROM threads")
		if e != nil {
			return e
		}
		for _, r := range rows {
			if len(r) != 1 || !uuidRE.MatchString(r[0]) || v.IDs[r[0]] {
				return fail("engine_db_unknown", "DB ID 구조 불명")
			}
			v.IDs[r[0]] = true
		}
		v.Count = len(rows)
		rows, e = query("SELECT parent_thread_id,child_thread_id,status FROM thread_spawn_edges")
		if e != nil {
			return e
		}
		ids := map[string]bool{}
		for _, m := range members {
			ids[m.ID] = true
		}
		for _, r := range rows {
			if len(r) != 3 || !uuidRE.MatchString(r[0]) || !uuidRE.MatchString(r[1]) || (r[2] != "open" && r[2] != "closed") {
				return fail("engine_db_unknown", "DB edge 구조 불명")
			}
			edge := object{"parent_thread_id": r[0], "child_thread_id": r[1], "status": r[2]}
			v.Edges = append(v.Edges, edge)
			if ids[r[0]] != ids[r[1]] {
				return fail("foreign_link", "DB에 묶음 밖 연결이 있습니다")
			}
		}
		_, e = query("COMMIT")
		return e
	}()
	rc, _, _ := funcs["sqlite3_close"].Call(db)
	if rc != 0 {
		return v, fail("engine_db_unknown", "DB handle 종료 실패")
	}
	if e := s.VerifyPrivate(); e != nil {
		inspectErr = errors.Join(inspectErr, fail("engine_db_changed", "private query 효과 또는 원본 acquisition 변경"))
	}
	if inspectErr != nil {
		return v, inspectErr
	}
	v.Observation, e = s.Observation()
	if e != nil {
		return v, e
	}
	v.Hashes = map[string]string{statePath: s.Files["state_5.sqlite"].Hash, statePath + "-wal": "absent"}
	if wal, exists := s.Files["state_5.sqlite-wal"]; exists {
		v.Hashes[statePath+"-wal"] = wal.Hash
	}
	if keep {
		v.Acquisition = s
	}
	return v, nil
}
func dbHashes(path string) (map[string]string, error) {
	m := map[string]string{}
	for _, p := range []string{path, path + "-wal"} {
		b, e := readBounded(p, limit)
		if os.IsNotExist(e) {
			m[p] = "absent"
			continue
		}
		if e != nil {
			return nil, e
		}
		m[p] = digest(b)
	}
	return m, nil
}
