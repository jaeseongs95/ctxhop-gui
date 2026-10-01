//go:build windows

package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"
)

// These capabilities are derived from native state and supported decoders.
// Neither a marker nor corrupt JSON confers rollback or cleanup authority.
type recoveryRecord struct {
	RecordID *string `json:"recordId"`
	OperationID *string `json:"operationId"`
	NativeID *string `json:"nativeId"`
	Path string `json:"path"`
	State string `json:"state"`
	SHA256 *string `json:"sha256"`
	CanRollback bool `json:"canRollback"`
	Files []string `json:"files"`
	Impl *string `json:"impl"`
	AbsenceKind *string `json:"absenceKind"`
	RetainedKinds []string `json:"retainedKinds"`
	ReasonCode *string `json:"reasonCode"`
	BlocksImport bool `json:"blocksImport"`
	CanResolve bool `json:"canResolve"`
	CanFinalizeLocal bool `json:"canFinalizeLocal"`
}
func pointer(s string) *string { return &s }
func recordProblem(r *recoveryRecord,state,code string) { r.State=state;r.ReasonCode=pointer(code);r.BlocksImport=true;r.CanRollback=false;r.CanResolve=false;r.CanFinalizeLocal=false }
type recoveryRecordLease struct { Dirs []snapshotEntry; File *os.File; Info syscall.ByHandleFileInformation; Bytes []byte }
func (l *recoveryRecordLease) Close() error {
	var e error;if l.File!=nil {e=l.File.Close();l.File=nil};for i:=len(l.Dirs)-1;i>=0;i-- {if l.Dirs[i].File!=nil {e=errors.Join(e,l.Dirs[i].File.Close())}};l.Dirs=nil;return e
}
// Every existing ancestor is a pinned directory. Only native not-found at the
// requested namespace/run is absence; a file ancestor is an unsafe record.
func pinRecoveryRecord(home,run string,mutate bool) (row recoveryRecord,l *recoveryRecordLease,retErr error) {
	path:=runPath(home,run);row=recoveryRecord{Path:path,State:"unsafe",Files:[]string{},RetainedKinds:[]string{},BlocksImport:true}
	if !opRE.MatchString(run) {recordProblem(&row,"unsafe","invalid_record_id");return row,nil,nil}
	row.RecordID=pointer(run);row.OperationID=pointer(run)
	l=&recoveryRecordLease{};defer func(){if retErr!=nil {retErr=errors.Join(retErr,l.Close())}}()
	anchors:=&dbAcquisition{};e:=anchors.lockDirs(home);l.Dirs=anchors.Dirs
	if e!=nil {recordProblem(&row,"unsafe","unsafe_ancestor");return row,l,nil}
	for _,p:=range []string{filepath.Dir(path),path} {
		entry,e:=snapshotOpen(p,true)
		if e==syscall.ERROR_FILE_NOT_FOUND || e==syscall.ERROR_PATH_NOT_FOUND {
			row.State="absent";row.BlocksImport=false;row.AbsenceKind=pointer("run_absent");return row,l,nil
		}
		if e!=nil {recordProblem(&row,"unsafe","unsafe_run");return row,l,nil};l.Dirs=append(l.Dirs,entry)
	}
	present:=[]string{}
	for _,name:=range []string{"journal.json","journal.resolved.json"} {
		u,_:=syscall.UTF16PtrFromString(filepath.Join(path,name));_,e:=syscall.GetFileAttributes(u)
		if e==nil {present=append(present,name)} else if e!=syscall.ERROR_FILE_NOT_FOUND {recordProblem(&row,"unsafe","record_probe_failed");return row,l,nil}
	}
	row.Files=present
	if len(present)!=1 {recordProblem(&row,"unreadable","record_missing");if len(present)>1 {row.ReasonCode=pointer("record_ambiguous")};return row,l,nil}
	row.Path=filepath.Join(path,present[0]);u,e:=syscall.UTF16PtrFromString(row.Path);if e!=nil {return row,l,e}
	access:=uint32(syscall.GENERIC_READ);if mutate {access|=0x10000}
	h,e:=syscall.CreateFile(u,access,syscall.FILE_SHARE_READ,nil,syscall.OPEN_EXISTING,0x00200000,0)
	if e!=nil {recordProblem(&row,"unsafe","record_open_failed");return row,l,nil};l.File=os.NewFile(uintptr(h),row.Path)
	l.Info,e=snapshotInfo(l.File,false);if e!=nil {recordProblem(&row,"unsafe","record_alias_or_reparse");return row,l,nil}
	size:=uint64(l.Info.FileSizeHigh)<<32|uint64(l.Info.FileSizeLow)
	if size>4<<20 {recordProblem(&row,"unsafe","record_size_limit");return row,l,nil}
	l.Bytes,e=io.ReadAll(io.LimitReader(l.File,(4<<20)+1));if e!=nil || uint64(len(l.Bytes))!=size {recordProblem(&row,"unsafe","record_read_failed");return row,l,nil}
	row.NativeID=pointer(snapshotFileID(l.Info));row.SHA256=pointer(digest(l.Bytes));row.CanResolve=true
	if present[0]=="journal.resolved.json" {row.State="resolved";row.BlocksImport=false;row.CanResolve=false;return row,l,nil}
	v,e:=parseJSON(l.Bytes);r:=obj(v)
	if e!=nil {recordProblem(&row,"unreadable","record_invalid_json");row.CanResolve=true;return row,l,nil}
	if !samePath(text(r["home"]),home) || !uuidRE.MatchString(text(r["id"])) {recordProblem(&row,"unreadable","record_binding_invalid");row.CanResolve=true;return row,l,nil}
	if r["impl"]=="ctxhop-codex" {
		row.Impl=pointer("ctxhop-codex");j,e:=decodeJournal(home,l.Bytes)
		if e!=nil {recordProblem(&row,"unreadable","record_contract_invalid");row.CanResolve=true;return row,l,nil}
		if j.LocalFinalization!=nil {
			if e:=validateLocalFinalization(home,run,j);e!=nil {recordProblem(&row,"unreadable","finalization_binding_invalid");return row,l,nil}
			row.AbsenceKind=j.LocalFinalization.AbsenceKind;row.RetainedKinds=j.LocalFinalization.RetainedKinds
			if j.LocalFinalization.State=="cleanup_pending" {row.State="cleanup_pending";row.CanResolve=false;row.CanFinalizeLocal=true;return row,l,nil}
		}
		row.CanRollback=j.Status=="pending" && j.LocalFinalization==nil
	} else if r["impl"]!=nil {
		recordProblem(&row,"unreadable","record_implementation_unknown");row.CanResolve=true;return row,l,nil
	} else if r["version"]!=nil {
		version,ok:=integer(r["version"]);if !ok || version!=2 || len(array(r["members"]))==0 {recordProblem(&row,"unreadable","record_legacy_invalid");row.CanResolve=true;return row,l,nil}
		row.Impl=pointer("python");row.CanRollback=r["status"]=="pending"
	} else {row.Impl=pointer("python");row.CanRollback=r["status"]=="pending"}
	switch r["status"] {
	case "pending":row.State="pending"
	case "complete","rolled_back":row.State=text(r["status"]);row.BlocksImport=false;row.CanRollback=false;row.CanResolve=false
	default:recordProblem(&row,"unreadable","record_status_unknown");row.CanResolve=true
	}
	return row,l,nil
}
func classifyRecoveryRecord(home,run string) (recoveryRecord,error) {
	r,l,e:=pinRecoveryRecord(home,run,false);if l!=nil {e=errors.Join(e,l.Close())};if e!=nil {recordProblem(&r,"unsafe","record_close_failed")};return r,e
}
func recoveryRecords(home string) ([]recoveryRecord,error) {
	anchors:=&dbAcquisition{};if e:=anchors.lockDirs(home);e!=nil {return []recoveryRecord{{Path:filepath.Join(home,".ctxhop-desktop-recovery"),State:"unsafe",Files:[]string{},RetainedKinds:[]string{},ReasonCode:pointer("unsafe_ancestor"),BlocksImport:true}},errors.Join(e,anchors.releaseLeases())}
	defer anchors.releaseLeases()
	root:=filepath.Join(home,".ctxhop-desktop-recovery");entry,e:=snapshotOpen(root,true)
	if e==syscall.ERROR_FILE_NOT_FOUND {return []recoveryRecord{},nil}
	if e!=nil {return []recoveryRecord{{Path:root,State:"unsafe",Files:[]string{},RetainedKinds:[]string{},ReasonCode:pointer("unsafe_namespace"),BlocksImport:true}},nil}
	entries,e:=entry.File.ReadDir(100001);e=errors.Join(e,entry.File.Close());if e!=nil && e!=io.EOF || len(entries)>100000 {return nil,fail("recovery_namespace","복구 목록 한도/읽기 오류")}
	rows:=make([]recoveryRecord,0,len(entries));for _,entry:=range entries {r,e:=classifyRecoveryRecord(home,entry.Name());if e!=nil {return nil,e};rows=append(rows,r)};return rows,nil
}
func recoveryResolve(home,run,sha string) (row recoveryRecord,retErr error) {
	row,l,e:=pinRecoveryRecord(home,run,true);if e!=nil {return row,e};if l==nil {return row,fail("unsafe_record","복구 기록을 열 수 없습니다")};defer func(){retErr=errors.Join(retErr,l.Close())}()
	if row.State=="resolved" && row.SHA256!=nil && *row.SHA256==sha {return row,nil}
	if !row.CanResolve || row.SHA256==nil || *row.SHA256!=sha {return row,fail("record_changed","표시한 복구 기록과 현재 bytes가 다릅니다")}
	dst:=filepath.Join(runPath(home,run),"journal.resolved.json")
	// FileRenameInfo on the validated READ|DELETE handle, no write/delete sharing.
	// The destination and all ancestors remain pinned; ReplaceIfExists is false.
	name,e:=syscall.UTF16FromString(dst);if e!=nil {return row,e};name=name[:len(name)-1]
	type renameInfo struct {Replace uint8;Root syscall.Handle;Length uint32;Name uint16}
	offset:=unsafe.Offsetof(renameInfo{}.Name);buffer:=make([]byte,int(offset)+2*len(name));header:=(*renameInfo)(unsafe.Pointer(&buffer[0]));header.Length=uint32(2*len(name))
	for i,c:=range name {*(*uint16)(unsafe.Pointer(&buffer[int(offset)+2*i]))=c}
	r,_,e:=proc("SetFileInformationByHandle").Call(l.File.Fd(),3,uintptr(unsafe.Pointer(&buffer[0])),uintptr(len(buffer)));if r==0 {return row,e}
	var info syscall.ByHandleFileInformation;if e=syscall.GetFileInformationByHandle(syscall.Handle(l.File.Fd()),&info);e!=nil || !snapshotIdentity(l.Info,info) || info.NumberOfLinks!=1 {return row,fail("record_changed","이름 변경 후 identity 오류")}
	final:=make([]uint16,32768);n,_,e:=proc("GetFinalPathNameByHandleW").Call(l.File.Fd(),uintptr(unsafe.Pointer(&final[0])),uintptr(len(final)),0)
	if n==0 || n>=uintptr(len(final)) || !samePath(syscall.UTF16ToString(final[:n]),`\\?\`+dst) {return row,fail("record_changed","이름 변경 후 최종 경로 오류")}
	row.Path=dst;row.State="resolved";row.Files=[]string{"journal.resolved.json"};row.CanRollback=false;row.CanResolve=false;row.CanFinalizeLocal=false;row.BlocksImport=false;row.ReasonCode=nil;return row,nil
}

func removeNewEmptyRun(path,id string) error {
	anchors:=&dbAcquisition{};if e:=anchors.lockDirs(filepath.Dir(path));e!=nil {return errors.Join(e,anchors.releaseLeases())};defer anchors.releaseLeases()
	entry,e:=snapshotOpen(path,true);if e!=nil {return e};if snapshotFileID(entry.Info)!=id {return errors.Join(fail("record_changed","새 run identity 변경"),entry.File.Close())}
	children,e:=entry.File.ReadDir(1);closeError:=entry.File.Close();if e!=nil && e!=io.EOF || len(children)!=0 || closeError!=nil {return errors.Join(fail("pending_record","새 run 잔여 항목은 보존합니다"),closeError)}
	return removeApprovalEntry(path,id,"",0,true)
}
