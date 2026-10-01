//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

type localFinalization struct {
	State string `json:"state"`
	ReceiptPath string `json:"receiptPath"`
	ReceiptSHA256 string `json:"receiptSha256"`
	ReceiptDigest string `json:"receiptDigest"`
	TerminalStatus string `json:"terminalStatus"`
	TerminalProof object `json:"terminalProof"`
	AbsenceKind *string `json:"absenceKind"`
	RetainedKinds []string `json:"retainedKinds"`
}
type ownedArtifact struct {
	Path string `json:"path"`
	Identity string `json:"identity"`
	Size int64 `json:"size"`
	SHA256 *string `json:"sha256"`
}
type finalizationReceipt struct {
	SchemaVersion int `json:"schemaVersion"`
	Kind string `json:"kind"`
	OperationID string `json:"operationId"`
	Home string `json:"home"`
	TerminalStatus string `json:"terminalStatus"`
	TerminalProofDigest *string `json:"terminalProofDigest"`
	ApprovalManifestSHA256 *string `json:"approvalManifestSha256"`
	RecoveryEvidenceDigest *string `json:"recoveryEvidenceDigest"`
	OwnedArtifacts []ownedArtifact `json:"ownedArtifacts"`
	ReceiptDigest string `json:"receiptDigest"`
}
func selfDigest(v any,key string) (string,error) {
	raw,e:=parseJSON(encoded(v));if e!=nil {return "",e};delete(obj(raw),key);b,e:=storeCanonicalJSON(raw);if e!=nil {return "",e};return digest(b),nil
}
func terminalDigest(proof object) (*string,error) {
	if proof==nil {return nil,nil};b,e:=storeCanonicalJSON(proof);if e!=nil {return nil,e};return pointer(digest(b)),nil
}
func artifactPath(run,relative string) (string,error) {
	if relative=="" || strings.ContainsAny(relative,"\\:") || strings.HasPrefix(relative,"/") || strings.Contains(relative,"//") {return "",fail("finalization_artifact","정리 artifact 경로 오류")}
	for _,part:=range strings.Split(relative,"/") {if part=="." || part==".." || part=="" {return "",fail("finalization_artifact","정리 artifact 경로 오류")}}
	allowed:=relative=="stage" || strings.HasPrefix(relative,"stage/") || relative=="ref" || strings.HasPrefix(relative,"ref/") || relative=="approval/members" || strings.HasPrefix(relative,"approval/members/") || relative=="recovery/rollouts" || strings.HasPrefix(relative,"recovery/rollouts/")
	if !allowed {return "",fail("finalization_artifact","허용되지 않은 정리 artifact")};return filepath.Join(run,filepath.FromSlash(relative)),nil
}
func receiptRead(home,run string,j *journal) (receipt finalizationReceipt,retErr error) {
	l:=j.LocalFinalization;if l==nil || j.Version!=4 || l.State!="cleanup_pending" && l.State!="complete" || !samePath(l.ReceiptPath,filepath.Join(runPath(home,run),"local-finalization.json")) || !hashRE.MatchString(l.ReceiptSHA256) || !hashRE.MatchString(l.ReceiptDigest) || l.TerminalStatus!="complete" && l.TerminalStatus!="rolled_back" || l.RetainedKinds==nil {return receipt,fail("finalization_binding","최종 정리 journal 계약 오류")}
	anchors:=&dbAcquisition{};defer func(){retErr=errors.Join(retErr,anchors.releaseLeases())}();if e:=anchors.lockDirs(runPath(home,run));e!=nil {return receipt,e}
	b,e:=readRecoveryRecord(l.ReceiptPath,true);if e!=nil || digest(b)!=l.ReceiptSHA256 {return receipt,fail("finalization_binding","최종 정리 receipt raw 결속 오류")}
	v,e:=parseJSON(b);r:=obj(v);n,ok:=integer(r["schemaVersion"])
	if e!=nil || !exact(r,"schemaVersion","kind","operationId","home","terminalStatus","terminalProofDigest","approvalManifestSha256","recoveryEvidenceDigest","ownedArtifacts","receiptDigest") || !ok || n!=1 || r["kind"]!="ctxhop-local-finalization-v1" || r["operationId"]!=run || !samePath(text(r["home"]),home) || r["terminalStatus"]!=l.TerminalStatus || r["receiptDigest"]!=l.ReceiptDigest {return receipt,fail("finalization_binding","최종 정리 receipt 계약 오류")}
	d,e:=selfDigest(r,"receiptDigest");if e!=nil || d!=l.ReceiptDigest {return receipt,fail("finalization_binding","최종 정리 canonical digest 오류")}
	proof,e:=terminalDigest(l.TerminalProof);if e!=nil || !bytes.Equal(encoded(proof),encoded(r["terminalProofDigest"])) {return receipt,fail("finalization_binding","historical terminal proof 결속 오류")}
	preplacing:=phases[j.Phase]<phases["placing"] && l.TerminalStatus=="rolled_back" && l.AbsenceKind!=nil && *l.AbsenceKind=="preplacing_target_absent"
	if proof==nil && !preplacing {return receipt,fail("finalization_binding","완료된 terminal proof 누락")}
	if proof!=nil {
		p:=l.TerminalProof
		if p["inputComplete"]!=true || p["home"]!=home || p["loaderContractId"]!=j.LoaderContractID || !hashRE.MatchString(text(p["projectionDigest"])) || !opRE.MatchString(text(p["acquisitionId"])) || !hashRE.MatchString(text(p["storeObservationDigest"])) || obj(p["storeProof"])==nil || j.ApprovalEvidence==nil || p["approvalEvidenceDigest"]!=j.ApprovalEvidence.ManifestSHA256 || !hashRE.MatchString(text(p["approvedMappingDigest"])) {return receipt,fail("finalization_binding","완료 historical proof 계약 오류")}
	}
	if j.ApprovalEvidence==nil {
		if !preplacing || r["approvalManifestSha256"]!=nil {return receipt,fail("finalization_binding","원승인 manifest 결속 누락")}
	} else {
		if r["approvalManifestSha256"]!=j.ApprovalEvidence.ManifestSHA256 {return receipt,fail("finalization_binding","원승인 manifest SHA 변경")}
		b,e:=readRecoveryRecord(j.ApprovalEvidence.ManifestPath,true);if e!=nil || digest(b)!=j.ApprovalEvidence.ManifestSHA256 {return receipt,fail("finalization_binding","compact 원승인 bytes 변경")}
		v,e:=parseJSON(b);m:=obj(v)
		if e!=nil || !exact(m,"schemaVersion","profile","archiveSha256","archiveFormat","operationId","home","cwd","pins","members") || m["profile"]!=approvalProfile || m["operationId"]!=run || !samePath(text(m["home"]),home) || m["archiveSha256"]!=j.ArchiveSHA256 || m["cwd"]!=j.Cwd || !bytes.Equal(encoded(m["pins"]),encoded(approvalPins{j.EngineSHA256,j.NormalEngineSHA256,j.LoaderContractID})) {return receipt,fail("finalization_binding","compact 원승인 계약 변경")}
		var manifest approvalManifest;if e=jsonDecodeStrict(b,&manifest);e!=nil {return receipt,e};if len(manifest.Members)!=len(j.Members) {return receipt,fail("finalization_binding","compact member 수 변경")}
		for i,m:=range manifest.Members {original:=j.Members[i];if m.ID!=original.ID || m.SessionID!=original.SessionID || !sameParent(m.ParentID,original.Parent) || m.Source.Size!=original.Size || m.Source.SHA256!=original.SHA256 || !bytes.Equal(encoded(m.ImmutableRolloutIDs),encoded(original.ImmutableRolloutIDs)) || m.ArchiveEntry!=original.ArchiveEntry || m.OriginBasename!=original.OriginBasename {return receipt,fail("finalization_binding","compact mapping 변경")}}
		mapping,e:=approvalMappingDigest(manifest.Members);if e!=nil || proof!=nil && l.TerminalProof["approvedMappingDigest"]!=mapping {return receipt,fail("finalization_binding","compact mapping digest 변경")}
	}
	if j.RecoveryEvidence==nil {if r["recoveryEvidenceDigest"]!=nil {return receipt,fail("finalization_binding","복구 digest 불일치")}} else {
		if r["recoveryEvidenceDigest"]!=j.RecoveryEvidence.ManifestSHA256 || proof!=nil && l.TerminalProof["recoveryEvidenceDigest"]!=j.RecoveryEvidence.ManifestSHA256 {return receipt,fail("finalization_binding","복구 digest 불일치")}
		b,e:=readRecoveryRecord(j.RecoveryEvidence.ManifestPath,true);if e!=nil || digest(b)!=j.RecoveryEvidence.ManifestSHA256 {return receipt,fail("finalization_binding","compact 복구 bytes 변경")}
		v,e:=parseJSON(b);m:=obj(v);if e!=nil || !exact(m,"schemaVersion","profile","operationId","home","approvalManifestSha256","rollouts") || m["profile"]!=recoveryProfile || m["operationId"]!=run || !samePath(text(m["home"]),home) || m["approvalManifestSha256"]!=j.ApprovalEvidence.ManifestSHA256 {return receipt,fail("finalization_binding","compact 복구 계약 오류")}
		if _,e=recoveryRollouts(m["rollouts"],options{Home:home,Run:run},j.Members,true);e!=nil {return receipt,e}
	}
	a,ok:=r["ownedArtifacts"].([]any);if !ok || len(a)>100000 {return receipt,fail("finalization_binding","정리 artifact 배열 오류")};seen:=map[string]bool{};identities:=map[string]bool{}
	for _,v:=range a {m:=obj(v);size,ok:=integer(m["size"]);relative:=text(m["path"]);id:=text(m["identity"])
		if !exact(m,"path","identity","size","sha256") || !ok || size<0 || size>limit || !fileIDRE.MatchString(id) || seen[strings.ToLower(relative)] || identities[id] || m["sha256"]!=nil && !hashRE.MatchString(text(m["sha256"])) || m["sha256"]==nil && size!=0 {return receipt,fail("finalization_binding","정리 artifact 계약 오류")};if _,e:=artifactPath(runPath(home,run),relative);e!=nil {return receipt,e};seen[strings.ToLower(relative)]=true;identities[id]=true
	}
	if e=jsonDecodeStrict(b,&receipt);e!=nil {return receipt,e};return receipt,nil
}
func jsonDecodeStrict(b []byte,v any) error {d:=json.NewDecoder(bytes.NewReader(b));d.DisallowUnknownFields();return d.Decode(v)}
func validateLocalFinalization(home,run string,j *journal) error {_,e:=receiptRead(home,run,j);return e}

// Pin the whole surviving candidate vector before deleting any entry. Empty
// directories are removed bottom-up; unknown children make deletion fail.
func finalizeLocal(home,run string) (result object,retErr error) {
	j,e:=loadJournal(home,run);if e!=nil {return nil,e};receipt,e:=receiptRead(home,run,j);if e!=nil {return nil,e}
	if j.LocalFinalization.State=="complete" {return object{"status":j.LocalFinalization.TerminalStatus,"run":run},nil}
	anchors:=&dbAcquisition{};defer func(){retErr=errors.Join(retErr,anchors.releaseLeases())}();if e=anchors.lockDirs(runPath(home,run));e!=nil {return nil,e}
	entries:=map[string]snapshotEntry{};defer func(){for _,entry:=range entries {if entry.File!=nil {retErr=errors.Join(retErr,entry.File.Close())}}}()
	deadline:=time.Now().Add(30*time.Second)
	for _,artifact:=range receipt.OwnedArtifacts {
		path,e:=artifactPath(runPath(home,run),artifact.Path);if e!=nil {return nil,e};directory:=artifact.SHA256==nil
		entry,e:=snapshotOpen(path,directory);if e==syscall.ERROR_FILE_NOT_FOUND || e==syscall.ERROR_PATH_NOT_FOUND {
			// Every still-existing ancestor must remain a native directory. A
			// file or reparse ancestor must not disguise a deleted artifact.
			for p:=filepath.Dir(path);within(runPath(home,run),p);p=filepath.Dir(p) {if _,e:=os.Lstat(p);os.IsNotExist(e) {continue};check,ce:=snapshotOpen(p,true);if ce!=nil {return nil,ce};if ce=check.File.Close();ce!=nil {return nil,ce};break};continue
		}
		if e!=nil {return nil,e};entries[artifact.Path]=entry
		if snapshotFileID(entry.Info)!=artifact.Identity {return nil,fail("finalization_artifact","정리 artifact identity 변경")}
		if !directory {h,size,e:=approvalHash(entry.File,artifact.Size,deadline);if e!=nil || size!=artifact.Size || h!=*artifact.SHA256 {return nil,fail("finalization_artifact","정리 artifact bytes 변경")}}
	}
	for _,artifact:=range receipt.OwnedArtifacts {
		entry,exists:=entries[artifact.Path];if !exists {continue};if e=entry.File.Close();e!=nil {return nil,e};entry.File=nil;entries[artifact.Path]=entry
		path,_:=artifactPath(runPath(home,run),artifact.Path);sha:="";if artifact.SHA256!=nil {sha=*artifact.SHA256}
		if e=removeApprovalEntry(path,artifact.Identity,sha,artifact.Size,artifact.SHA256==nil);e!=nil {return nil,e}
	}
	j.Status=receipt.TerminalStatus;j.CleanupStatus="";j.LocalFinalization.State="complete";if e=saveJournal(runPath(home,run),j,false);e!=nil {return nil,e};return object{"status":j.Status,"run":run},nil
}

func beginFinalization(run string,j *journal,target string) error {
	if j.LocalFinalization!=nil {_,e:=finalizeLocal(j.Home,filepath.Base(run));return e}
	preplacing:=phases[j.Phase]<phases["placing"] && target=="rolled_back"
	if !preplacing && j.TerminalProof==nil {return fail("finalization_binding","최종 fresh proof 없이 정리할 수 없습니다")}
	proof,e:=terminalDigest(j.TerminalProof);if e!=nil {return e}
	receipt:=finalizationReceipt{SchemaVersion:1,Kind:"ctxhop-local-finalization-v1",OperationID:filepath.Base(run),Home:j.Home,TerminalStatus:target,TerminalProofDigest:proof,OwnedArtifacts:[]ownedArtifact{}}
	if j.ApprovalEvidence!=nil {receipt.ApprovalManifestSHA256=pointer(j.ApprovalEvidence.ManifestSHA256)};if j.RecoveryEvidence!=nil {receipt.RecoveryEvidenceDigest=pointer(j.RecoveryEvidence.ManifestSHA256)}
	// Pin original/recovery copies before recording ownership. Compact manifests
	// are retained and remain bound independently of their deleted source slots.
	o:=options{Home:j.Home,Run:filepath.Base(run),Cwd:j.Cwd,ApprovalEvidence:j.ApprovalEvidence,RecoveryEvidence:j.RecoveryEvidence}
	if j.ApprovalEvidence!=nil {l,e:=pinApproval(o,j.Members);if e!=nil {return e};if j.ApprovalOwnership==nil || !bytes.Equal(encoded(l.Ownership),encoded(j.ApprovalOwnership)) {return errors.Join(fail("finalization_binding","원승인 ownership 변경"),l.Close())};if e=l.Close();e!=nil {return e}}
	if j.RecoveryEvidence!=nil {l,e:=pinRecovery(o,j.Members);if e!=nil {return e};if e=l.Close();e!=nil {return e}}
	if j.ReferenceApprovalEvidence!=nil {
		ref:=options{Home:filepath.Join(run,"ref"),Run:filepath.Base(run),Cwd:j.Cwd,ApprovalEvidence:j.ReferenceApprovalEvidence};l,e:=pinApproval(ref,j.Members);if e!=nil {return e};if j.ReferenceApprovalOwnership==nil || !bytes.Equal(encoded(l.Ownership),encoded(j.ReferenceApprovalOwnership)) {return errors.Join(fail("finalization_binding","reference ownership 변경"),l.Close())};if e=l.Close();e!=nil {return e}
		b,e:=readRecoveryRecord(ref.ApprovalEvidence.ManifestPath,true);if e!=nil {return e};if e=createFile(filepath.Join(run,"reference-approval-manifest.json"),b);e!=nil {return e}
	}
	for _,prefix:=range []string{"stage","ref","approval/members","recovery/rollouts"} {
		root:=filepath.Join(run,filepath.FromSlash(prefix));if _,e:=os.Lstat(root);os.IsNotExist(e) {continue}
		e:=filepath.WalkDir(root,func(path string,d os.DirEntry,walkErr error)error {
			if walkErr!=nil {return walkErr};relative,_:=filepath.Rel(run,path);relative=filepath.ToSlash(relative);if _,e:=artifactPath(run,relative);e!=nil {return e}
			if !finalizationKnownPath(relative,j) {return fail("finalization_artifact","미확인 정리 항목은 보존합니다")}
			entry,e:=snapshotOpen(path,d.IsDir());if e!=nil {return e};artifact:=ownedArtifact{Path:relative,Identity:snapshotFileID(entry.Info)}
			if !d.IsDir() {h,size,e:=approvalHash(entry.File,limit,time.Now().Add(30*time.Second));if e!=nil {return errors.Join(e,entry.File.Close())};artifact.Size=size;artifact.SHA256=pointer(h)}
			if e=entry.File.Close();e!=nil {return e};receipt.OwnedArtifacts=append(receipt.OwnedArtifacts,artifact);return nil
		});if e!=nil {return e}
	}
	sort.Slice(receipt.OwnedArtifacts,func(i,k int)bool {a,b:=receipt.OwnedArtifacts[i],receipt.OwnedArtifacts[k];if a.SHA256!=nil && b.SHA256==nil {return true};if a.SHA256==nil && b.SHA256!=nil {return false};if strings.Count(a.Path,"/")!=strings.Count(b.Path,"/") {return strings.Count(a.Path,"/")>strings.Count(b.Path,"/")};return a.Path<b.Path})
	receipt.ReceiptDigest,e=selfDigest(receipt,"receiptDigest");if e!=nil {return e};b:=append(encoded(receipt),'\n');if len(b)>4<<20 {return fail("resourceLimit","최종 정리 receipt 크기 초과")};path:=filepath.Join(run,"local-finalization.json");if e=createFile(path,b);e!=nil {return e}
	absence:=pointer("terminal_source_absence");if preplacing {absence=pointer("preplacing_target_absent")};j.LocalFinalization=&localFinalization{State:"cleanup_pending",ReceiptPath:path,ReceiptSHA256:digest(b),ReceiptDigest:receipt.ReceiptDigest,TerminalStatus:target,TerminalProof:j.TerminalProof,AbsenceKind:absence,RetainedKinds:[]string{"journal","local_finalization","approval_manifest","recovery_manifest"}}
	j.Status="pending";if e=saveJournal(run,j,false);e!=nil {return e};_,e=finalizeLocal(j.Home,filepath.Base(run));if e!=nil {return e};j.Status=target;j.LocalFinalization.State="complete";return nil
}
func finalizationKnownPath(relative string,j *journal) bool {
	for i:=range j.Members {for _,prefix:=range []string{"stage/","approval/members/"} {if relative==fmt.Sprintf("%s%04d.jsonl",prefix,i) {return true}}}
	if relative=="stage" || relative=="approval/members" || relative=="recovery/rollouts" {return true}
	if strings.HasPrefix(relative,"recovery/rollouts/") {return j.RecoveryEvidence!=nil}
	if !strings.HasPrefix(relative,"ref/") && relative!="ref" {return false}
	if j.ReferenceApprovalEvidence==nil {return false}
	name:=filepath.Base(relative)
	if relative=="ref" || relative=="ref/sessions" || relative=="ref/stage" || relative=="ref/.ctxhop-desktop-recovery" || relative=="ref/.ctxhop-desktop-recovery/"+filepath.Base(filepath.Dir(filepath.Dir(j.ApprovalEvidence.ManifestPath))) {return true}
	if relative=="ref/config.toml" {return true}
	if snapshotCanonicalBase(strings.TrimSuffix(strings.TrimSuffix(name,"-wal"),"-shm")) && filepath.Dir(relative)=="ref" {return true}
	for i,m:=range j.Members {if relative==fmt.Sprintf("ref/stage/%04d.jsonl",i) || relative=="ref/sessions/"+filepath.Base(m.Path) {return true}}
	refRoot:="ref/.ctxhop-desktop-recovery/"+filepath.Base(filepath.Dir(filepath.Dir(j.ApprovalEvidence.ManifestPath)))+"/approval"
	if relative==refRoot || relative==refRoot+"/members" || relative==refRoot+"/manifest.json" {return true};for i:=range j.Members {if relative==fmt.Sprintf("%s/members/%04d.jsonl",refRoot,i) {return true}};return false
}
