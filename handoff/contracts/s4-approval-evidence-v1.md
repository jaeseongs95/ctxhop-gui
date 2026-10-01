# S4 approval evidence 구현 계약 — 개정 1

2026-10-01. 기존 V1/V2 개정4에 추가하는 로컬 구현 계약이다. root가 사용자에게 받은 S4 명세·구현·격리시험 권한 안에서 결정했다. mapping HIGH 패널의 실제 4 blind·4 cross·별도 fresh Judge 조건부 판단과 root가 확인한 고정 source를 사용했다. panel record의 설치 validator 불일치 때문에 이를 valid handoff/실행 승인으로 소비하지 않는다. 제품 수용·push·PR·원본 삭제 승인이나 새 권한을 발급하는 문서가 아니다.

판정 원자료: `deliberation-r45/mapping-panel/judge-verdict.json` SHA `7F775E7CC7DBA44C10CA3DA6277C699DD97FC75B53F396C00CA3F534E22899A6`. root 기록의 source locator 전사 오류는 `decision-record-v3.json`에서 정확한 frozen Git 경로로 정정했다. 원 질문/dossier/Judge와 초기 serialization 실패는 보존했다. v3 기록도 completed/reused에 대한 설치 validator 오류 5개로 FAIL이며 승인 근거로 쓰지 않는다.

## 승인 경계와 source 수명

기존 지원 Go의 명시적 plan token 확인 → archive/support 재검증 → pinned engine stdin bridge가 scope 승인 경계다. Rust는 원 ZIP을 재파싱하지 않는다. archive SHA·entry 순서/size/SHA와 basename/profile는 Go가 실제 검증한 provenance다. Rust는 owned 원본 member 전체의 실제 bytes/identity/size/full SHA와 shared canonical decoder를 확인한다. 같은 SID의 악의적 Go/journal/evidence 교체에 대한 암호학적 승인 인증을 보장하지 않는다. 새 PKI/secret/전역 ACL을 만들지 않는다.

신규 v4 journal의 원본 승인 manifest는 불변이며, `run/approval/manifest.json`과 `run/approval/members/%04d.jsonl`을 CREATE_NEW로 저장한다. 원본 member는 archive의 rollout bytes 그대로다. stage는 별도 실제 파일이며 배치로 이동해도 evidence를 잃지 않는다. durable evidence와 manifest SHA를 journal에 기록한 뒤에만 placing 이후 단계로 진행한다. 디렉터리/파일 ownership·regular·reparse/hardlink/alias·size/hash 및 exact path containment는 기존 검증을 재사용한다. 논리 경로만으로 파일 identity를 보장하지 않는다.

pending/needs_attention/취소/부분 실패/재시작에서는 evidence를 보존한다. 완료 또는 rolled_back을 판정하고 fresh proof, 준비/실행 엔진 종료 및 owned Job0을 확인한 뒤 identity-checked evidence를 정리한다. 정리에 실패하면 pending/needs_attention 또는 별도 복구 가능한 cleanup 상태를 남긴다. terminal 저장·정리 순서는 기존 journal 원자 저장과 retry 규칙을 이용하며 정리 실패를 성공으로 숨기지 않는다. manual-resolved는 기존 bounded owned journal 비교/이동 의미를 유지하며 all8 absence proof가 아니다.

## 최소 manifest와 wire

manifest는 중복·누락·unknown field를 거절하는 exact object다. 새 wire는 `contractVersion=2`를 유지하지만 mapping profile과 새 loader/source 핀으로 구분한다. old exact wire를 새 지원으로 조용히 수용하지 않는다.

manifest top-level exact9:

```json
{
  "schemaVersion": 1,
  "profile": "ctxhop-approval-member-v1",
  "archiveSha256": "lowercase SHA256",
  "archiveFormat": 1,
  "operationId": "owned journal run ID",
  "home": "absolute operation home",
  "cwd": "absolute requested cwd",
  "pins": {"engineSha256":"...","normalEngineSha256":"...","loaderContractId":"..."},
  "members": []
}
```

archiveFormat은 기존 실제 지원 1 또는 2다. pins exact3는 journal·실제 pinned bridge와 일치한다. operationId/home/cwd/member order는 소유 journal 및 현재 prepare와 일치한다. reference는 기존 소유 ref 홈에 별도 scope manifest를 만들고 원 bytes를 재사용할 수 있지만, 부모 journal scope를 해당 홈의 승인으로 묵시 치환하지 않는다.

manifest member exact8:

```json
{
  "id": "M",
  "parentId": null,
  "role": "root",
  "immutableRolloutIds": ["R"],
  "sessionId": "Q",
  "archiveEntry": "rollout.jsonl",
  "originBasename": "original canonical rollout basename",
  "source": {"path":"absolute owned evidence path","size":1,"sha256":"..."}
}
```

source exact3, pins exact3, parentId는 required nullable다. child role/parent와 순서 규칙은 기존 exact5 Member와 같고 manifest 모든 M/order/parent/role가 요청과 일치해야 한다. format2 archiveEntry는 실제 `rollouts/%04d.jsonl`이다. source path·archive entry·origin basename은 각각 다른 의미다. stage의 `0000.jsonl`에서 R을 도출하지 않는다. 현재 ordinary Go 지원에서는 origin basename과 canonical source M이 일치하므로 초기 R=M 한 개를 확정한다. Q는 canonical decoder의 session_id 키 부재 때만 Q=M이며 explicit null/empty/nonstring/잘못된 UUID는 거절한다. legacy child의 Q를 부모나 tree root로 정규화하지 않는다.

PrepareRequest는 기존 exact7에 required nullable `approvalEvidence` 한 개를 추가해 exact8로 한다. descriptor exact3는 `profile`, `manifestPath`, `manifestSha256`이며 body/header/settings bytes는 pipe에 보내지 않는다. 기존 wire Member exact5는 유지한다. Plan/Bootstrap의 무구성원 prepare는 descriptor null을 허용한다. Import/Reference/Cold/Rollback/RollbackCheck의 구성원이 있는 prepare는 descriptor가 필수다. Rollback의 actual rolloutPath/SHA null pair는 계속 허용하며 가상 path를 만들지 않는다.

projection에는 `mappingProfile`(항상 위 literal), `approvalEvidenceDigest`, `approvedMappingDigest` 세 필드를 추가한다. 미완료/무구성원 prepare의 두 digest는 required null이다. completed context는 검증된 evidence manifest SHA와 typed mapping의 canonical digest를 보유한다. projectionDigest에는 이 필드들을 포함한다. Binding exact7와 CompleteRequest exact8는 그대로 두고 current process/nonce/snapshot/generation/operation, 실제 acquisitionId/storeObservationDigest와 projectionDigest로 결속한다. loader profile/source 변경과 함께 Go/PS exact projection validator 및 provider를 갱신한다.

approvedMappingDigest는 순서가 있는 exact member summaries의 canonical digest다: `id,parentId,role,immutableRolloutIds,sessionId,archiveEntry,originBasename,sourceSize,sourceSha256`. owned evidence path나 engine generation은 이 summary에서 제외하지만 manifest full SHA와 projectionDigest가 actual path/scope에 결속한다. plan token은 archive SHA/home/cwd/engine·normal·loader·mapping profile, 같은 immutable summary와 기존 stable policy/config projection을 포함한다. nonce/context/acquisition 등의 매번 바뀌는 필드는 stable token에서 제외한다. import 때 같은 token을 다시 계산하고 이후 engine이 source와 typed mapping을 독립 확인한다.

## actual inventory와 historical coverage

current inventory는 M/R/Q/parent/history_base 및 parse uncertainty를 보존한다. ordinary/revert/compressed/current/archived/alternate/pending staging를 기존 strict parser로 확인하며 R과 M이 다른 경우를 몰래 같게 바꾸지 않는다. 승인 mapping을 actual 값으로 덮어쓰지 않는다. actual path/identity/hash와 source evidence path/identity/hash도 별도다.

private threadHistory의 네 표에서 모든 bounded typed history key를 분류한다. M∪known R은 target 조회에 필요하지만 historical closure를 증명하지 않는다. current strict inventory 또는 지속된 canonical source에서 소유가 확인된 unrelated key는 허용한다. ownerless/ambiguous/malformed key 또는 소유 근거가 사라진 과거 R은 unknown이다. target과 무관함을 증명할 수 없는 unknown이 있으면 전체 durable0/import collision 없음/rollbackAbsent/rollbackRetained/delete 가능성 proof를 발급하지 않는다. schema에 없는 R→M registry를 추정 backfill하거나 원본 migration하지 않는다.

삭제 전 실제 발견한 target R 집합과 canonical source owner 증거는 소유 복구 evidence로 지속 보존해 postdelete retry에서 검증할 수 있게 한다. 이 관측은 original approval을 바꾸거나 새 M/Q/parent를 승인하지 않는다. 추가 R의 소유는 기존 approved M/Q와 canonical actual/source/history_base의 exact 증거로 다시 확인하며 문자열 선언만으로 known R에 넣지 않는다. immutable source와 verified recovery inventory는 별도 객체/저장 단계로 관리한다. 검증 가능한 source가 없으면 unknown으로 남긴다. 최종 구현의 구체적 저장 형식은 두 구현자가 연결 전에 root에 제출하고 기존 digest/phase/ownership API를 재사용한다.

import collision은 passive 포함0, rollbackAbsent는 file/state/구조/actual8의 전체 durable0이다. rollbackRetained는 기존 exact passive allowlist `state.migrationCursor`, `queue.revision`, `agentMessageBoard.deletedBoard`만 허용하며 active/foreign/unknown0이어야 한다. all-marker에서는 activate/delete/resume/application RPC0이고 readonly proof 종료·abort/EOF/Job0 후 owned journal만 정리한다. mixed는 정확한 canonical present subtree와 실제 fixture가 마련될 때까지 차단한다. 정상 canonical delete의 history-first 순서를 orphan 생성 증거로 왜곡하지 않는다.

## v3 호환

v3 status/list/manual-resolved/rolled_back idempotence와 exact engine/normal/loader pin rollback 검사를 보존한다. 기존 preplacing target-file-absent local stage/ref cleanup 예외를 유지하지만 all8 absence나 삭제권한으로 표현하지 않는다. 새 evidence를 자동 추정하거나 v3를 자동 rewrite/upgrade하지 않는다.

현재 exact 지원 old/new compatibility pair가 없으므로 자동 migration 경로를 만들지 않는다. 별도 recover-migrate/명시 opt-in을 지원하려면 원 v3 raw/SHA 보존, action·member scope·archiveSHA·exact old/new pins/schema/profile·decoder fixture, 원 source size/hash/order/basename 재확보, crash/idempotence 근거가 필수다. 해당 profile이 없거나 source가 소실된 absent/postdelete v3는 needs_attention이다. 새 엔진 자기 선언이나 version 문자열 유사성으로 old pins를 대체하지 않는다. 기존 수동 해결은 유지한다.

## 자원·실패 한도

기존 archive/member/해제 총1GiB·entry2002·member2000·line16MiB를 유지한다. source 고유 총1GiB는 actual8 main+기존 WAL 총1GiB와 별개이며 SHM 각16MiB/전체128MiB도 그대로다. full hash는 ≤64KiB chunk streaming, shared canonical line decoder는 LF 제외16MiB 한도로 처리한다. declared size 대신 실제 bounded bytes/EOF/hash를 확인하고 checked arithmetic을 사용한다. source/body 원문은 wire/log/오류에 넣지 않는다.

manifest와 journal은 기존 수동 복구와 맞는 ≤4MiB serialized UTF8를 요구하며 초과는 placing 전 resourceLimit로 멈춘다. frame은 terminal LF 제외 serialized UTF8 JSON ≤16MiB로 Go/Rust의 요청/성공/오류 양방향에 적용한다. 수신 max+1, EOF partial·embedded raw newline·중복/unknown field 거절, 송신 전 actual byte 크기 확인을 한다. 기존 더 짧은 query/Job 제한을 보존하고 새 read/hash/decode/query 작업은 monotonic per-RPC30초 deadline과 취소에 결속한다. partial scan/timeout/cancel에서 completed proof를 만들지 않고 reader·native handles를 명시 종료한 뒤 attention으로 남긴다.

실제 inventory 한정 profile은 candidate≤100000, file stream≤1GiB, 고유 읽은 bytes≤8GiB/pass다. 초과/deadline/불확실성은 unknown이며 일부 scan을 전체 부재로 돌려주지 않는다. 이는 유한 자원 검증 profile이고 모든 기존 홈 지원 완료를 의미하지 않는다. broad 지원 목표와 검증된 unrelated 수용을 유지한다. 범위 확대/숨은 기존 변경이 필요하면 concrete 근거를 root에 제시한다.

## 필수 회귀와 소유권

typed M/R/Q(ordinary/revert/legacy child/null malformed), stage basename, duplicate/dual owner, stale/forged tuple/hash, approval-vs-actual mismatch, source lifetime(staged/present/absent/postdelete/restart/archive 소실), alias/reparse/partial/size/hash/slot/basename 불일치, unknown old R/known unrelated, v3 strict pins/preplacing/manual/terminal, 16MiB exact/+1/1MiB초과/UTF8/EOF, 2000/+1/line/aggregate overflow·timeout·취소·정리 실패를 검사한다. Judge A1~A10의 실제 runtime/actual8/marker/first+cold/V2/manual 회귀와 별도 최종 감사가 전체 완료 조건이다.

helper1은 P 전체 Rust·canonical inventory/provider/runtime와 sole Cargo target 소유자다. helper2는 R/impl/codex Go member/archive/journal/source/wire/token 및 tagged runner만 소유한다. root는 PS/Worker/exact validators/docs/catalog/provider/build/CI 및 최종 통합을 소유한다. helper3는 지정 runner/toolchain과 새 owned-debug-probe subtree만 소유한다. 공유 index에 남의 파일을 넣거나 reset/clean/기존 seed를 재사용하지 않는다. 시험은 scoped commit의 `git -c core.autocrlf=false archive` 새 사본에서만 돌린다. Rust profile의 migration CRLF와 known schema를 명시하고 production image와 libtest fixture pins를 구별한다.
