# S4 recovery evidence·records 구현 계약 — 개정 1

2026-10-01. root의 기존 S4 로컬 명세·구현·새 합성 시험 권한 안에서 작성한 명시 구현 계약이다. 원 `s4-approval-evidence-v1.md` SHA `2132EABCC4D398C02839FEFA2D8A12AAB68024763892F74912001CD1D53DF571`를 보존하고 아래 추가 interface·수명·분류 규칙만 보충한다. push/PR·공개·실제 사용자 데이터 접근/변경 권한은 없다. 모든 시험은 고정 commit의 `git -c core.autocrlf=false archive` 새 사본에서만 한다.

원자료는 recovery-records-panel의 root 직접 확인 frozen R `4df0ce175c1b666dd33a84864c3ab1fcead97673`/P `feffebd9cfde1fd0b6cf719c4110410db354be1e`, dossier SHA `A70FEF3A8AD073094649653EC5FB05C9C3009C6CD82C2EE68E78C3D5560FF8F1`, 별도 fresh Judge SHA `4E5E3AE921929B18F84A61FF9860C266560AA9667E77D51E251ED2814AE36BB3`다. blind4+cross3(4 triggers)+fresh Judge1의 조건부 설계 판단이며 제품 PASS가 아니다. truthful DecisionRecord SHA `A15DC1AECC6ABD8D147A9D5C6453002DD1EEE0D1524CBD90E8ECA1BE534834A9`는 설치 validator의 completed/reused 모순 4건으로 FAIL이다. 이를 valid handoff나 실행 승인으로 소비하지 않으며 ID/status/plugin을 바꾸지 않는다. root는 원 사용자 권한과 확인한 원자료 아래 아래 설계를 선택한다. 구현 후 별도 fresh 독립 최종 감사가 필요하다.

## 1. 원 approval과 새 recovery 입력

original manifest exact9/member exact8/source exact3, archive/member order·M/Q/parent/source SHA, `approvedMappingDigest`와 사용자 plan token 의미는 바꾸지 않는다. current 추가 R은 새 M/Q/parent 승인도 전역 registry도 아니다. Rust 준비 과정은 원본 SQLite open/query0, application/network/durable evidence writes0이며 Go가 sole durable writer다.

PrepareRequest는 원 exact7 + required nullable `approvalEvidence` + required nullable `recoveryEvidence` = **exact9**다. `contractVersion=2`, wire Member exact5, Binding exact7와 CompleteRequest exact8는 유지한다. 무구성원 Plan/Bootstrap은 두 descriptor null이다. 구성원 있는 prepare는 원 approval이 필수이며 초기 fact prepare의 recovery는 null일 수 있다. 최종 proof에 필요한 추가 R source가 없으면 unknown으로 실패한다. 새 loader/source pins를 함께 갱신하며 이전 exact wire를 조용히 수용하지 않는다.

`recoveryEvidence` descriptor exact3:

```json
{"profile":"ctxhop-recovery-inventory-v1","manifestPath":"absolute owned run/recovery/manifest.json","manifestSha256":"lowercase SHA256"}
```

manifest는 CREATE_NEW/fsync된 **exact6**다. 중복·unknown·누락 field를 거절한다.

```json
{"schemaVersion":1,"profile":"ctxhop-recovery-inventory-v1","operationId":"owned 32hex run","home":"absolute operation home","approvalManifestSha256":"original immutable approval manifest SHA","rollouts":[]}
```

각 rollout은 **exact7**이며 parentId/historyBase는 required nullable다.

```json
{"id":"M","sessionId":"Q","immutableRolloutId":"R","originBasename":"actual canonical origin filename","parentId":null,"historyBase":null,"source":{"path":"absolute source path","size":1,"sha256":"lowercase raw SHA256"}}
```

source exact3. historyBase가 있으면 canonical HistoryPosition **exact3 snake_case** `{"thread_id":"R","end_ordinal_exclusive":0,"end_byte_offset":0}`이며 두 수는 u64다. M/R/Q를 서로 같게 정규화하지 않는다. historyBase R만으로 owning M을 만들지 않는다. 원 승인 R 집합 밖의 실제 추가 target R만 한 번씩 담는다. 각 M/Q/parent는 원 approval scope에 속하고 Rust의 canonical full source로 독립 재확인돼야 한다. duplicate R·dual owner·declared tuple와 raw source의 불일치·빠진 필요 R·unknown historical owner는 proof를 막는다.

persisted source는 `run/recovery/rollouts/%06d.jsonl` 또는 `%06d.jsonl.zst`이며 000000부터 연속 index다. 순서는 M의 원 member order, 그 안의 canonical R ordinal 문자열 오름차순이다. 물리 suffix는 실제 raw format과 일치하고 originBasename은 별도 실제 이름이다. slot basename에서 R을 도출하지 않는다. approval의 `%04d.jsonl` profile을 확장하지 않는다. actual source와 owned copy는 별도 native identity다. path/size/SHA는 wire 선언일 뿐 Go와 Rust가 각각 regular/nonalias/reparse/ancestors/final-path/actual size/EOF/full SHA를 직접 검사한다. 동일 identity를 가진 서로 다른 evidence 경로는 hardlink/alias로 거절한다.

completed projection에 required nullable **`recoveryEvidenceDigest`**를 추가하고 projectionDigest에 포함한다. 값은 검증한 recovery manifest의 실제 SHA다. null은 검증된 추가 입력 없음만 뜻하고 필요한 source가 없음을 성공으로 바꾸지 않는다. 미완료 projection은 원 approval/mapping digest 규칙과 같이 recovery digest null이다. approvedMappingDigest는 original summary만 유지한다.

v4 journal은 required nullable `recoveryEvidence` descriptor와 required nullable `localFinalization`을 새 생성 때 명시한다. 이전 개발 중 v4의 누락값은 null로 읽을 수 있으나 새 wire/pin을 bypass하지 않는다. v3는 원 raw schema/필드·strict pins·status/manual/preplacing/terminal idempotence를 유지하고 자동 rewrite/upgrade0이다.

## 2. B 전용 fact 메서드와 fresh second

전용 **`ctxhop/recovery-plan`**을 추가한다. params는 현재 incomplete prepared process의 Binding exact7 echo이며 operation은 `rollback` 또는 `rollback-check`다. 일반 complete의 final actual8 proof/Acceptance 의미를 바꾸지 않는다.

response **exact4**:

```json
{"phase":"recoveryPlan","inputComplete":false,"binding":{},"plan":{"schemaVersion":1,"profile":"ctxhop-recovery-plan-v1","operationId":"owned run","home":"absolute home","approvalManifestSha256":"original approval SHA","rollouts":[],"planDigest":"lowercase SHA256"}}
```

plan **exact7**, rollout은 위 exact7 fact shape이고 source.path는 발견한 **actual** source다. 이 source.path가 persisted owned slot으로 치환된 뒤 새 manifest를 만드는 것은 Go의 별도 쓰기다. planDigest는 **전체 exact4 result에서 plan.planDigest 한 필드만 제외**한 canonical compact UTF8 JSON의 SHA256다. 기존 shared digest 규칙(객체 keys ordinal sort, array order/정수 보존)을 재사용하고 Go/Rust golden byte fixtures를 공유한다. current binding/phase/false/모든 facts를 포함한다. 새로운 binding/generation을 만들거나 incomplete를 complete로 표시하지 않는다.

첫 prepare+fact request의 SQL/all8 acquisition/proof는0, `acquisitionId/storeObservationDigest/storeProof`는 explicit null, Acceptance=None이다. canonical actual inventory/full-tail owner/source hash를 읽기만 한다. 성공 후 internal **DiscoveryIssued**로 전환하며 같은 pipe는 현재 binding의 abort 또는 EOF만 허용한다. complete/accept/activate/recovery-plan 재호출과 다른 binding은 거절한다. fact 응답은 cross-process 승인이나 최종 proof가 아니다.

한 명시 rollback/recover action은 다음 한 cycle만 자동 수행한다.

1. first prepared fact process에서 실제 추가 R 목록을 받는다. original scope, 정확한 response/digest/binding, source format/순서/bounds를 Go가 확인한다.
2. Go가 actual source를 native pin한 동일 handles에서 raw opaque full bytes를 CREATE_NEW owned slot으로 복사·hash/EOF 확인한다. persisted combined budget와 같은 SHA/size를 확인하고 manifest fsync→journal descriptor 원자 저장을 마친다. 실패/부분 저장은 보존한다.
3. first process를 abort/EOF, pipe drain·native explicit close·owned Job active0 후 종료한다. 종료 확인 실패는 fresh second/삭제로 진행하지 않는다.
4. **fresh second**는 새 nonce/process/snapshot/generation으로 original approval + durable recovery + 실제 current inventory/subtree + 전체 bounded historical keys + actual8 private acquisition을 독립 검사한 complete에서만 Acceptance를 만든다. first plan/old projection을 current proof로 재사용하지 않는다.

fresh second에서 새 미보존 R·source mismatch·inventory 변경·unknown·취소·한도 초과가 있으면 attention이다. 자동 expansion/reseal loop0이며 이후 새로운 명시 복구 action이 필요하다. postdelete fresh proof, first/cold compatibility 등 전체 engine phase를2로 제한하지 않는다. 기존 validated recovery가 이미 있는 retry는 이를 독립 검사하고 필요한 새 fact→copy cycle은 같은 explicit action당 최대1회다. 원 manifest를 overwrite/append하지 않는다. 기존 recovery와 다른 추가 입력이 필요한 경우 기존 evidence는 보존하고 attention으로 멈춘다; 현 profile에 자동 manifest generation/replacement는 없다.

## 3. canonical full source와 자원 한도

Go는 zstd raw를 해제하지 않고 표준 라이브러리 streaming copy/hash만 한다. Rust는 기존 zstd decoder(window_log_max=23)와 rollout-owned canonical parser를 재사용하되 **exact pinned handle**만 읽는다. sibling resolve/path reopen/materialize_for_append/header-only를 full-tail/EOF witness로 치환하지 않는다. raw+expanded 모두 bounded checked count와 monotonic per-RPC30초/취소를 적용한다. 반복 line만 deadline 검사하고 blocking decode/read가 무한히 남는 경로를 허용하지 않는다.

첫 SessionMeta가 owning M/Q/parent/historyBase의 유일한 근거다. 기존 canonical recorder가 허용하는 fork history의 later SessionMeta를 별도 owner로 승격하지 않고 유효한 역사 항목으로 읽는다. duplicate JSON key와 copied SessionMeta를 구별한다. legacy ghost 변환 및 first own metadata의 unknown history_mode 거부를 원 reader와 공유하고 meaningful compatibility fixtures로 검증한다. malformed/unknown tail은 parse-error count로 성공 처리하지 않고 unknown이다. typed body UUID로 R→M을 추정하지 않는다. historyBase byte offset은 expanded JSONL boundary이고 ordinal은 원 canonical history contract를 따른다. 이 호환성 규칙이 원 approval source 파서에도 적용된다.

- persisted approval+recovery raw source 물리 합계≤1073741824 bytes. 같은 내용의 별도 물리 사본·reference scope 사본·partial 복사도 각각 peak budget에 센다. 같은 검증된 동일 물리 source 재사용만 한 번 센다. 논리 SHA 같다고 물리 copy count를 없애지 않는다.
- 파일별 raw stream≤1GiB, expanded stream≤1GiB. raw+expanded 처리량 checked 합계≤8589934592 bytes/pass. plain raw는 한 번 센다. expanded 총합1GiB라는 더 좁은 새 전역 한도는 없다.
- line LF 제외≤16777216 bytes, chunk≤65536 bytes, manifest/journal/receipt serialized UTF8≤4194304 bytes, wire terminal LF 제외≤16MiB, inventory candidate≤100000. 모든 overflow·partial·EOF 오류·timeout·cancel은 proof 없이 attention이다.
- archive/stage 기존 총1GiB/entry/member 한도는 별도다. actual8 main+WAL 총1GiB, SHM 각16MiB/합128MiB도 별도다. 각 pass/RPC는 유한하고 더 짧은 기존 query/Job deadline을 보존한다.

## 4. terminal local finalization

full source가 있는 fresh terminal proof와 actual postconditions, 준비/실행 reader·engine 종료·owned Job0를 확인한 뒤만 evidence 삭제 전에 아래 local receipt를 만든다. receipt는 역사적 local cleanup intent이며 fresh all8/absence/known R/engine 승인으로 사용할 수 없다.

owned `run/local-finalization.json` CREATE_NEW/fsync **exact10**:

```json
{"schemaVersion":1,"kind":"ctxhop-local-finalization-v1","operationId":"owned run","home":"absolute home","terminalStatus":"complete","terminalProofDigest":"lowercase historical projection SHA","approvalManifestSha256":"original approval manifest SHA","recoveryEvidenceDigest":null,"ownedArtifacts":[],"receiptDigest":"lowercase canonical SHA"}
```

terminalStatus는 complete 또는 rolled_back. terminalProofDigest는 아래 journal.localFinalization.terminalProof의 canonical compact SHA며 complete/placing 이후 rollback은 **당시에 직접 검증한 completed projection 전체**다. fresh guard/source freshness/종료/Job0를 지나기 전 receipt를 만들지 않는다. 기존 preplacing target-absent local rollback 예외는 terminalProof와 terminalProofDigest가 null일 수 있고 engine/all8 proof가 아님을 유지한다. original manifest가 아직 없는 preplacing 실패는 approval SHA도 null일 수 있다. 두 경우 모두 required nullable 필드이며 unknown를 null로 성공 처리하는 일반 예외는 아니다.

receiptDigest는 이 exact10 object에서 자기 field 하나만 제외한 canonical SHA다. 파일 raw SHA는 journal에 별도로 결속한다. ownedArtifacts 각 **exact4** `{path,identity,size,sha256}`. path는 **run-relative** separator `/`, `..`/absolute/alternate stream/unknown prefix0이며 stage/ref/approval member/recovery rollout의 직접 검증한 후보만 허용한다. files는 actual native identity/nonalias/size/fullSHA, directories는 actual native identity/size0/sha256null로 기록하며 bottom-up 비재귀 empty 삭제만 한다. 후보 전체와 native directory ancestors/run anchor를 cleanup 전에 직접 확인하고 unknown entry나 변조/alias가 있으면 보존/attention이다. 원 journal/receipt/compact original+recovery manifests는 정리 목록에 넣지 않는다. ref nested manifest는 original reference scope가 보존된 compact 위치를 먼저 CREATE_NEW 저장·결속한 후만 원 ref 정리에 포함할 수 있다. 미검증 ref entries를 recursive delete하지 않는다.

v4 `localFinalization`은 required nullable, 존재하면 **exact8** `{state,receiptPath,receiptSha256,receiptDigest,terminalStatus,terminalProof,absenceKind,retainedKinds}`다. receiptPath는 exact owned local-finalization.json, SHA는 raw receipt bytes, state는 cleanup_pending 또는 complete다. terminalProof는 historical validated completed projection 또는 위 preplacing null 예외. absenceKind/retainedKinds는 그때의 직접 판정과 exact passive allowlist 의미를 보존한다. compact manifests/원 M/order/mapping/sourceSHA/pins/journal 결속은 삭제하지 않는다. journal metadata와 descriptor를 읽는 cleanup-only validator는 source file existence를 요구하거나 engine reader에 이 journal을 넘기지 않는다.

순서는 **receipt durable → journal status pending + localFinalization cleanup_pending 원자 저장 → 모든 후보 prevalidate → identity-checked cleanup → journal 최종 terminal + localFinalization complete 원자 저장**이다. journal 결속 없는 receipt 단독은 cleanup권한0. receipt 존재/저장실패/부분 cleanup/최종 저장 실패를 성공으로 숨기지 않는다. 실패는 pending cleanup_pending 또는 needs_attention으로 남긴다.

source-less restart는 검증된 journal/receipt/보존 compact manifests만으로 **owned cleanup와 local terminal 저장만** 재시도한다. 새 DB/open/query/acquisition/proof0, engine/activate/resume/delete/applicationRPC0, target application writes0이다. 남은 후보는 exact identity/size/hash+containment를 다시 확인하고 실제 없는 owned artifact만 idempotent 처리한다. 예전 proof로 current authority를 발급하거나 새 engine pins 불일치를 original operation에 우회하지 않는다. cleanup-only는 engine 실행을 요구하지 않지만 stored exact pins와 원 immutable mapping 결속을 검증한다. v3는 새 receipt migration 없이 원 의미를 보존한다.

## 5. Go 공유 records classifier와 외부 adapter

GUI가 Go import를 막는 기록을 absent로 숨기지 않도록 Go의 단일 native classifier를 pendingRuns·status/list/resolve와 PS/Worker/GUI가 공유한다. ancestor/root가 unsafe면 traverse하지 않고 명시 진단 또는 실패를 반환한다. absent는 요청된 owned run이 **실제로 없을 때만**이다. owned empty/tmp-only run·both journal·invalid-name·reparse/alias/hardlink·oversize·close 실패는 visible unreadable/unsafe + reasonCode다. invalid-name namespace issue는 recordId/operationId/nativeId/SHA null, actions0이고 actual path만 진단한다. unknown marker/project 연결로 이를 rollback 허가로 쓰지 않는다.

Go CLI는 `recovery-list --home`, `recovery-status --home --run`, `recovery-resolve --home --run --sha256`, cleanup-only `finalize --home --run`를 제공한다. readonly status/list와 safe raw resolve는 engine pin/engine 실행/SQLite/원 approval 보호 DACL을 새 선행조건으로 요구하지 않는다. strict native regular/containment/size/hash/alias 안전은 필수다. args의 unrelated flags·bad SHA/ID는 거절한다.

list output exact1 `{records:[]}`, status exact1 `{record:{}}`. record row **exact15** `{recordId,operationId,nativeId,path,state,sha256,canRollback,files,impl,absenceKind,retainedKinds,reasonCode,blocksImport,canResolve,canFinalizeLocal}`. absent의 ID/path는 요청된 owned 값이고 SHA null/actions0/blocksImportfalse. unsafe diagnostic의 null IDs 규칙은 위와 같다. reasonCode는 안정 식별자이며 민감한 body/path 내용을 error에 복제하지 않는다. files/null·retainedKinds 배열·capability bool은 actual supported decoder/receipt 판정으로 만든다. 성공 resolved/complete/rolled_back은 native-safe bounded 단일 record일 때만 blocksImportfalse다. valid pending은 blocksImporttrue이며 rollback engine scope 검사는 실행 단계에서 다시 한다. unreadable의 단일 safe raw는 canResolvetrue, unsafe/both/missing는 false다. cleanup_pending은 pending+blocksImporttrue/canRollbackfalse/canResolvefalse/canFinalizeLocaltrue다. unsupported identity/binding인 receipt는 canFinalizeLocalfalse다.

manual resolve는 caller recordId/SHA를 실제 live bounded raw(≤4MiB)와 비교하고 **같은 native handle로 no-replace rename**한다. READ+DELETE access, 다른 write/delete 공유0, retained ancestor/destination anchors, final path·regular/nonalias/fileID·fullSHA, rename 뒤 identity, explicit close를 확인한다. path-based 검사 뒤 [IO.File]::Move를 쓰지 않는다. 손상 JSON도 이 안전 raw 조건이면 기존 수동 closure 허용. caller identity token을 새 필수값으로 추가하지 않는다. 안전한 단일 resolved는 위 검사를 통과한 뒤 기존 idempotence 성공만 제공하고 body로 authority를 만들지 않는다. both records는 하나를 골라 SHA를 만들지 않는다. manual resolved는 evidence를 삭제하지 않는다.

Python legacy journals도 동일 raw native safety classifier를 거쳐 metadata를 기존 호환 규칙으로 표시하고 legacy rollback은 기존 backend에 위임한다. Go v4 body로 변환하지 않는다. 최초 journal save 실패는 현재 요청이 만든 동일 identity의 empty run과 app writes0를 확인한 비재귀 제거만 허용한다. tmp/unknown entry·정리 실패는 보존 진단, 기존 orphan 자동삭제0이다.

PS는 exact row/capabilities를 검증하고 Worker merge가 reasonCode/blocksImport/canResolve/canFinalizeLocal을 보존한다. GUI는 해당 capability로 버튼을 활성화한다. 별도 finalize는 vendor-owned cleanup만 실행하며 project undo/marker 승인과 묶지 않는다. status가 absent/unreadable거나 marker가 불명인 사실만으로 project rollback 허가를 만들지 않는다. 기존 다른 vendor와 valid marker의 rollback 동작은 유지한다.

## 6. 필수 검증과 소유권

한 직접 native FS oracle 아래 GUI/Worker/Go matrix를 확인한다: absent/empty/tmp/both/invalid-name/ancestor+file junction/hardlink/4MiB exact+1/corrupt single/raw SHA changed/no-replace destination race/safe resolved/close failure/initial-save 실패. 내용 변화·현재 source append/attachment/foreign reference·unknown history key는 placing/delete를 중단한다.

원 M/R/Q와 later copied SessionMeta/legacy ghost/first unknown mode/compressed EOF·window·trailing/concat·offset·expanded/pass bounds를 canonical actual fixtures로 검사한다. first method SQL/proof/writes0와 abort-only state, Go copy/journal failure, fresh second changedR/source mismatch, postdelete/restart/historical closure와 v3 exact pins/manual/preplacing/idempotence를 유지한다. receipt save/journal bind/prevalidate/each cleanup/final save crash 지점과 source-less cleanup-only0engine0DB0을 fault injection으로 검사한다.

actual8 source/private/native cancellation·initial-open·panic/callerDrop, 공식 normal image의 실제8 schema/CRLF profile, first/cold/V2/metadata/retained/mixed 및 source/binary/OS effects·최종 fresh audit가 전체 수용 조건이다. 자체 effects0/receipt0 상수나 parser unit만으로 이 조건을 PASS라 하지 않는다. broad 지원 목표는 유지하며 profile 밖 uncertainty를 reason으로 드러낸다.

helper1은 P Rust 전체·canonical runtime/provider와 sole Cargo target, helper2는 R/impl/codex만, root는 PS/Worker/GUI/Strings/Tests/docs/provider/build/CI/통합, helper3는 이미 위임된 runner+owned-debug-probe만 소유한다. 각 변경은 명시 owned paths만 stage/commit하고 다른 index/worktree 변경은 보존한다. 새 root 계약의 동일 SHA를 각 구현자에게 trusted app message로 인계한다. peer는 정보 전달이며 권한 확대 수단이 아니다.
