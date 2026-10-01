//go:build windows

package main

// Go preserves opaque rollout bytes. Only the pinned Rust canonical reader
// interprets compressed or historical content; a discovery fact grants no proof.
import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const recoveryProfile = "ctxhop-recovery-inventory-v1"
const recoveryPlanProfile = "ctxhop-recovery-plan-v1"

type recoveryDescriptor struct {
	Profile string `json:"profile"`
	ManifestPath string `json:"manifestPath"`
	ManifestSHA256 string `json:"manifestSha256"`
}
type recoveryRollout struct {
	ID string `json:"id"`
	SessionID string `json:"sessionId"`
	ImmutableRolloutID string `json:"immutableRolloutId"`
	OriginBasename string `json:"originBasename"`
	ParentID *string `json:"parentId"`
	HistoryBase object `json:"historyBase"`
	Source approvalSource `json:"source"`
}
type recoveryManifest struct {
	SchemaVersion int `json:"schemaVersion"`
	Profile string `json:"profile"`
	OperationID string `json:"operationId"`
	Home string `json:"home"`
	ApprovalManifestSHA256 string `json:"approvalManifestSha256"`
	Rollouts []recoveryRollout `json:"rollouts"`
}
type recoveryLease struct {
	Manifest recoveryManifest
	Dirs []snapshotEntry
	Files []snapshotEntry
}
func recoveryPath(o options) string { return filepath.Join(runPath(o.Home,o.Run),"recovery","manifest.json") }
func (l *recoveryLease) Close() error {
	var e error
	for _, entries := range [][]snapshotEntry{l.Files,l.Dirs} {
		for i:=len(entries)-1;i>=0;i-- { if entries[i].File!=nil { e=errors.Join(e,entries[i].File.Close()) } }
	}
	l.Files=nil; l.Dirs=nil
	return e
}
func recoveryDescriptorValid(d *recoveryDescriptor,o options) bool {
	return d!=nil && d.Profile==recoveryProfile && hashRE.MatchString(d.ManifestSHA256) && samePath(d.ManifestPath,recoveryPath(o))
}
func unsigned(v any) bool {
	n,ok:=v.(json.Number); if !ok {return false}; _,e:=strconv.ParseUint(n.String(),10,64); return e==nil
}
func recoveryRollouts(v any,o options,ms []member,owned bool) ([]recoveryRollout,error) {
	a,ok:=v.([]any); if !ok || len(a)>100000 {return nil,fail("recovery_evidence","복구 inventory 배열 오류")}
	byID:=map[string]member{}; order:=map[string]int{}; approved:=map[string]bool{}
	for i,m:=range ms { byID[m.ID]=m; order[m.ID]=i; for _,r:=range m.ImmutableRolloutIDs {approved[r]=true} }
	seen:=map[string]bool{}; out:=make([]recoveryRollout,0,len(a)); prevOrder:=-1; prevR:=""
	for i,v:=range a {
		r:=obj(v); src:=obj(r["source"]); m,known:=byID[text(r["id"])]; rid:=text(r["immutableRolloutId"])
		if !exact(r,"id","sessionId","immutableRolloutId","originBasename","parentId","historyBase","source") || !exact(src,"path","size","sha256") || !known || r["sessionId"]!=m.SessionID || !uuidRE.MatchString(rid) || approved[rid] || seen[rid] || !hashRE.MatchString(text(src["sha256"])) {
			return nil,fail("recovery_evidence","복구 rollout scope/tuple 오류")
		}
		parent:=any(nil); if m.Parent!=nil {parent=*m.Parent}; if r["parentId"]!=parent {return nil,fail("recovery_evidence","복구 parent 승인 범위 오류")}
		history:=obj(r["historyBase"])
		if r["historyBase"]!=nil && (!exact(history,"thread_id","end_ordinal_exclusive","end_byte_offset") || !uuidRE.MatchString(text(history["thread_id"])) || !unsigned(history["end_ordinal_exclusive"]) || !unsigned(history["end_byte_offset"])) {return nil,fail("recovery_evidence","복구 historyBase 오류")}
		size,ok:=integer(src["size"]); path:=text(src["path"]); origin:=text(r["originBasename"]); name:=rolloutNameRE.FindStringSubmatch(origin)
		if !ok || size<1 || size>limit || !filepath.IsAbs(path) || filepath.Clean(path)!=path || name==nil || name[1]!=rid || filepath.Base(origin)!=origin || strings.Contains(origin,":") {return nil,fail("recovery_evidence","복구 source 경로/크기 오류")}
		suffix:=".jsonl"; if strings.HasSuffix(origin,".jsonl.zst") {suffix+=".zst"}
		if owned {
			if !samePath(path,filepath.Join(filepath.Dir(recoveryPath(o)),"rollouts",fmt.Sprintf("%06d%s",i,suffix))) {return nil,fail("recovery_evidence","복구 slot 경로 오류")}
		} else if filepath.Base(path)!=origin || !within(filepath.Join(o.Home,"sessions"),path) && !within(filepath.Join(o.Home,"archived_sessions"),path) {return nil,fail("recovery_evidence","복구 원자료 containment 오류")}
		position:=order[m.ID]; if position<prevOrder || position==prevOrder && rid<=prevR {return nil,fail("recovery_evidence","복구 inventory 순서/중복 오류")}
		prevOrder=position; prevR=rid; seen[rid]=true
		out=append(out,recoveryRollout{m.ID,m.SessionID,rid,origin,m.Parent,history,approvalSource{path,size,text(src["sha256"])}})
	}
	return out,nil
}
func validateRecoveryPlan(r object,s *session) ([]recoveryRollout,error) {
	p:=obj(r["plan"]); n,ok:=integer(p["schemaVersion"])
	if !exact(r,"phase","inputComplete","binding","plan") || r["phase"]!="recoveryPlan" || r["inputComplete"]!=false || s.Projection["inputComplete"]!=false || s.Operation!="rollback" && s.Operation!="rollback-check" || s.Projection["acquisitionId"]!=nil || s.Projection["storeObservationDigest"]!=nil || s.Projection["storeProof"]!=nil || !exact(p,"schemaVersion","profile","operationId","home","approvalManifestSha256","rollouts","planDigest") || !ok || n!=1 || p["profile"]!=recoveryPlanProfile || p["operationId"]!=s.Options.Run || !samePath(text(p["home"]),s.Options.Home) || s.Options.ApprovalEvidence==nil || p["approvalManifestSha256"]!=s.Options.ApprovalEvidence.ManifestSHA256 || !hashRE.MatchString(text(p["planDigest"])) { return nil,fail("recovery_plan","복구 fact 응답 계약 오류") }
	if e:=validateRPCBindingV2(obj(r["binding"]));e!=nil {return nil,e}
	actual,e:=storeCanonicalJSON(r["binding"]); if e!=nil {return nil,e}; expected,e:=storeCanonicalJSON(s.Binding); if e!=nil || !bytes.Equal(actual,expected) {return nil,fail("recovery_plan","복구 fact binding 변경")}
	v,e:=parseJSON(encoded(r));if e!=nil {return nil,e}; delete(obj(obj(v)["plan"]),"planDigest"); b,e:=storeCanonicalJSON(v)
	if e!=nil || digest(b)!=p["planDigest"] {return nil,fail("recovery_plan","복구 fact digest 불일치")}
	return recoveryRollouts(p["rollouts"],s.Options,s.Members,false)
}
func (s *session) recoveryPlan() ([]recoveryRollout,error) {
	if s.DiscoveryIssued {return nil,fail("recovery_plan","복구 fact는 한 번만 요청할 수 있습니다")}
	if e:=validateRPCBindingV2(s.Binding);e!=nil {return nil,e}
	r,e:=s.Call("ctxhop/recovery-plan",s.Binding)
	// Once discovery was requested no admission may reuse this process, even if
	// its response is malformed or its pipe failed.
	s.DiscoveryIssued=true; previous:=s.Call
	s.Call=func(method string,params object)(object,error){
		if method!="ctxhop/abort" {return nil,fail("recovery_plan","복구 discovery 뒤 abort만 허용합니다")}
		a,_:=storeCanonicalJSON(params);b,_:=storeCanonicalJSON(s.Binding); if !bytes.Equal(a,b) {return nil,fail("recovery_plan","abort binding 변경")};return previous(method,params)
	}
	if e!=nil {return nil,e};return validateRecoveryPlan(r,s)
}
func pinRecovery(o options,ms []member) (l *recoveryLease,retErr error) {
	if o.RecoveryEvidence==nil {return nil,nil}
	if !recoveryDescriptorValid(o.RecoveryEvidence,o) || o.ApprovalEvidence==nil {return nil,fail("recovery_evidence","복구 descriptor 결속 오류")}
	l=&recoveryLease{};defer func(){if retErr!=nil {retErr=errors.Join(retErr,l.Close())}}()
	anchors:=&dbAcquisition{}; e:=anchors.lockDirs(filepath.Dir(o.RecoveryEvidence.ManifestPath)); l.Dirs=anchors.Dirs;if e!=nil {return l,e}
	entry,e:=snapshotOpen(o.RecoveryEvidence.ManifestPath,false);if e!=nil {return l,e};l.Files=append(l.Files,entry)
	b,e:=io.ReadAll(io.LimitReader(entry.File,(4<<20)+1)); if e!=nil || len(b)>4<<20 || digest(b)!=o.RecoveryEvidence.ManifestSHA256 {return l,fail("recovery_evidence","복구 manifest bytes 변경")}
	v,e:=parseJSON(b);r:=obj(v);n,ok:=integer(r["schemaVersion"])
	if e!=nil || !exact(r,"schemaVersion","profile","operationId","home","approvalManifestSha256","rollouts") || !ok || n!=1 || r["profile"]!=recoveryProfile || r["operationId"]!=o.Run || !samePath(text(r["home"]),o.Home) || r["approvalManifestSha256"]!=o.ApprovalEvidence.ManifestSHA256 {return l,fail("recovery_evidence","복구 manifest 계약 오류")}
	rollouts,e:=recoveryRollouts(r["rollouts"],o,ms,true);if e!=nil {return l,e}
	l.Manifest=recoveryManifest{1,recoveryProfile,o.Run,o.Home,o.ApprovalEvidence.ManifestSHA256,rollouts}
	dir,e:=snapshotOpen(filepath.Join(filepath.Dir(recoveryPath(o)),"rollouts"),true);if e!=nil {return l,e};l.Dirs=append(l.Dirs,dir)
	entries,e:=dir.File.ReadDir(len(rollouts)+1);if e!=nil && e!=io.EOF || len(entries)!=len(rollouts) {return l,fail("recovery_evidence","복구 slot 추가/누락")}
	rootEntries,e:=l.Dirs[len(l.Dirs)-2].File.ReadDir(3);if e!=nil && e!=io.EOF || len(rootEntries)!=2 {return l,fail("recovery_evidence","복구 root 추가/누락")}
	for _,entry:=range rootEntries {if entry.Name()!="manifest.json" && entry.Name()!="rollouts" {return l,fail("recovery_evidence","복구 root 항목 오류")}}
	var total int64; ids:=map[string]bool{};deadline:=time.Now().Add(30*time.Second)
	for _,m:=range ms {if m.Size>limit-total {return l,fail("resourceLimit","승인/복구 원자료 합계 초과")};total+=m.Size}
	for _,r:=range rollouts {
		if r.Source.Size>limit-total {return l,fail("resourceLimit","승인/복구 원자료 합계 초과")};total+=r.Source.Size
		entry,e:=snapshotOpen(r.Source.Path,false);if e!=nil {return l,e};l.Files=append(l.Files,entry);id:=snapshotFileID(entry.Info)
		if ids[id] {return l,fail("recovery_evidence","복구 물리 identity 중복")};ids[id]=true
		h,size,e:=approvalHash(entry.File,r.Source.Size,deadline);if e!=nil || h!=r.Source.SHA256 || size!=r.Source.Size {return l,fail("recovery_evidence","복구 source bytes 변경")}
	}
	return l,nil
}

// All source handles and ancestors are retained from validation through copy.
// CREATE_NEW failures preserve every partial artifact for explicit attention.
func persistRecovery(o options,ms []member,rollouts []recoveryRollout) (descriptor *recoveryDescriptor,retErr error) {
	if o.ApprovalEvidence==nil {return nil,fail("recovery_evidence","원승인 결속 누락")}
	if o.RecoveryEvidence!=nil {
		l,e:=pinRecovery(o,ms);if e!=nil {return nil,e}; defer func(){retErr=errors.Join(retErr,l.Close())}()
		if len(l.Manifest.Rollouts)!=len(rollouts) {return nil,fail("recovery_evidence","기존 복구 inventory 변경")}
		for i,r:=range rollouts {old:=l.Manifest.Rollouts[i];old.Source.Path=r.Source.Path;if !bytes.Equal(encoded(old),encoded(r)) {return nil,fail("recovery_evidence","기존 복구 tuple 변경")}}
		return o.RecoveryEvidence,nil
	}
	if len(rollouts)==0 {return nil,nil}
	l:=&recoveryLease{};defer func(){retErr=errors.Join(retErr,l.Close())}()
	var total int64;for _,m:=range ms {if m.Size>limit-total {return nil,fail("resourceLimit","승인 원자료 합계 초과")};total+=m.Size}
	deadline:=time.Now().Add(30*time.Second);ids:=map[string]bool{}
	for _,r:=range rollouts {
		if r.Source.Size>limit-total {return nil,fail("resourceLimit","승인/복구 물리 합계 초과")};total+=r.Source.Size
		anchors:=&dbAcquisition{};e:=anchors.lockDirs(filepath.Dir(r.Source.Path));l.Dirs=append(l.Dirs,anchors.Dirs...);if e!=nil {return nil,e}
		entry,e:=snapshotOpen(r.Source.Path,false);if e!=nil {return nil,e};l.Files=append(l.Files,entry);id:=snapshotFileID(entry.Info)
		if ids[id] {return nil,fail("recovery_evidence","복구 원자료 identity 중복")};ids[id]=true
		h,size,e:=approvalHash(entry.File,r.Source.Size,deadline);if e!=nil || h!=r.Source.SHA256 || size!=r.Source.Size {return nil,fail("recovery_evidence","복구 원자료 bytes 변경")}
	}
	root:=filepath.Dir(recoveryPath(o));if e:=os.Mkdir(root,0700);e!=nil {return nil,e};if e:=os.Mkdir(filepath.Join(root,"rollouts"),0700);e!=nil {return nil,e}
	manifest:=recoveryManifest{1,recoveryProfile,o.Run,o.Home,o.ApprovalEvidence.ManifestSHA256,make([]recoveryRollout,0,len(rollouts))}
	for i,r:=range rollouts {
		suffix:=".jsonl";if strings.HasSuffix(r.OriginBasename,".jsonl.zst") {suffix+=".zst"};path:=filepath.Join(root,"rollouts",fmt.Sprintf("%06d%s",i,suffix))
		out,e:=os.OpenFile(path,os.O_WRONLY|os.O_CREATE|os.O_EXCL,0600);if e!=nil {return nil,e}
		src:=l.Files[i].File;_,e=src.Seek(0,io.SeekStart);var copied int64
		buffer:=make([]byte,64<<10);for e==nil {if e=approvalExpired(deadline);e!=nil {break};var n int;n,e=src.Read(buffer);if int64(n)>r.Source.Size-copied {e=fail("recovery_evidence","복구 copy 크기 변경");break};if n>0 {w,we:=out.Write(buffer[:n]);copied+=int64(w);if we!=nil {e=we}else if w!=n {e=io.ErrShortWrite}};if e==io.EOF {e=nil;break}}
		if e==nil && copied!=r.Source.Size {e=fail("recovery_evidence","복구 copy EOF 크기 변경")};if e==nil {e=out.Sync()};e=errors.Join(e,out.Close());if e!=nil {return nil,e}
		copy,e:=snapshotOpen(path,false);if e!=nil {return nil,e};h,size,e:=approvalHash(copy.File,r.Source.Size,deadline);id:=snapshotFileID(copy.Info);e=errors.Join(e,copy.File.Close())
		if e!=nil || h!=r.Source.SHA256 || size!=r.Source.Size || ids[id] {return nil,fail("recovery_evidence","복구 copy 검증 실패")};ids[id]=true;r.Source.Path=path;manifest.Rollouts=append(manifest.Rollouts,r)
	}
	b:=append(encoded(manifest),'\n');if len(b)>4<<20 {return nil,fail("resourceLimit","복구 manifest 크기 초과")};if e:=createFile(recoveryPath(o),b);e!=nil {return nil,e}
	descriptor=&recoveryDescriptor{recoveryProfile,recoveryPath(o),digest(b)};check:=o;check.RecoveryEvidence=descriptor;verified,e:=pinRecovery(check,ms);if e!=nil {return nil,e};return descriptor,verified.Close()
}

func cloneJSON(v any) any { value,e:=parseJSON(encoded(v));if e!=nil {panic(e)};return value }

func prepareRecoveryEngine(o options,j *journal,ms []member) (second *session,recovered options,retErr error) {
	recovered=o
	first,e:=prepareEngine(o,"rollback",ms);if e!=nil {return nil,recovered,e}
	closed:=false;defer func(){if !closed {retErr=errors.Join(retErr,first.Close())}}()
	rollouts,e:=first.recoveryPlan();if e!=nil {return nil,recovered,e}
	d,e:=persistRecovery(o,j.Members,rollouts);if e!=nil {return nil,recovered,e}
	if d!=nil {j.RecoveryEvidence=d;recovered.RecoveryEvidence=d;if e=saveJournal(runPath(o.Home,o.Run),j,false);e!=nil {return nil,recovered,e}}
	// Closing owns EOF, drains pipes and waits for Job active zero. A failure
	// prevents the fresh process and every subsequent application action.
	if e=first.Close();e!=nil {return nil,recovered,e};closed=true
	second,e=prepareEngine(recovered,"rollback",ms);return second,recovered,e
}
