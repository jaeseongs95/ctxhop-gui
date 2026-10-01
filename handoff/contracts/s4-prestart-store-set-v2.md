# S4 protected engine store-set 계약 v2 초안

상태: root 소유의 구현 계약 개정4, 2026-10-01. 양쪽 구현 담당자와 별도 설계 검토의 F1~F8을 반영한다. descriptor/acquisition 분리와 relation catalog는 구현 기준으로 채택한다. 개정4는 외부 complete/binding의 v2 필드 이름과 버전 결속을 확정한다. rollbackRetained의 최종 API 소비자 검증은 별도 필수 gate로 남긴다. 이 문서는 구현·실제 엔진·수용 PASS를 발급하지 않는다. 기존 `s4-prestart-contract-v1.md`의 정책·인증·설정·순서·자동 삭제 금지는 유지하고 아래 wire/여러 저장소 읽기/원본 보존 terminal marker를 명시적으로 확장한다. state-only v1 시험은 하위 근거로 보존하며 v2 전체 수용으로 사용하지 않는다.

## 변경 이유와 경계

고정 vendor `ff6aec96948b70d94983af2641a6b67c94faeff5`의 SqliteConfig는 7개 DB를 열거한다. 별도 extension의 `agent_message_board_1.sqlite`도 같은 sqlite home을 사용하며 feature가 꺼져 있어도 영구 삭제의 cleanup 경로에 참여한다. source map `deliberation-r45/r45-other-store-source-map.md`(SHA256 `3f59f35e745928f4946e0b67d5114704d545cdc4ddf539373cace7cecf9551ff`)가 직접 확인한 경로를 근거로 한다. 기존 보조 DB 존재 자체를 거부하는 안전 장치는 이 계약의 구현·검증 뒤 실제 참조 검사로 대체한다.

정상 설정·SqliteConfig·DB 위치를 private root로 바꾸지 않는다. 원본 SQLite open/ATTACH, migration, repair, backup/reset, source SHM 복사는 금지한다. 모든 query는 새 finalized private copy에만 수행한다. 기존 홈의 관련 없는 정상 보조 DB·행은 허용하는 것이 목표다. 구조·typed 관계·효과를 해석하지 못하는 경우 이유를 밝혀 차단한다.

## wire와 descriptor

production prepare/complete/accept/activate는 `contractVersion:2`만 사용한다. loader ID prefix는 `ctxhop-prestart-v2:`이고 provider manifest·Go·PS의 pin도 함께 갱신한다. v1 complete를 v2로 자동 승격하거나 배열을 생략한 caller를 state-only로 수용하지 않는다. 일반 transport/effects/contexts와 기존 binding 값의 의미는 v1 규칙을 유지한다. 아래 명시한 v2 필드는 외부 요청에도 필수이며, 내부 검증 함수의 부분 object를 외부 RPC binding으로 사용하지 않는다.

prepare projection에 `proofTargets`를 추가한다. exact ordered 목록은 다음 8개이며 각 원소는 `{kind,path}`다.

| kind | canonical filename |
|---|---|
| state | state_5.sqlite |
| logs | logs_2.sqlite |
| goals | goals_1.sqlite |
| memories | memories_1.sqlite |
| memoriesV2 | memories_v2_1.sqlite |
| queue | queue_1.sqlite |
| threadHistory | thread_history_1.sqlite |
| agentMessageBoard | agent_message_board_1.sqlite |

첫 7개는 실제 SqliteConfig getter, 보드는 extension의 실제 descriptor 함수를 공유한다. 보드 descriptor를 string literal만 복제하거나 기능 비활성이라는 이유로 누락하지 않는다. `writeTargets`의 domain은 SQLite이며 가능한 7+board 경로를 같은 순서로 포함한다. 이는 rollout/name-index/기타 filesystem 쓰기를 열거했다는 뜻이 아니며 해당 효과는 별도 runtime gate가 검사한다. prestart에서 feature/cleanup 경로로 다른 DB가 열릴 수 있으면 input unknown으로 차단한다. `proofTargets`는 feature와 무관하게 항상 8개다. 8개 path의 부모는 같은 canonical sqlite home이어야 한다. 정상 root와 path/ancestor identity, 중복 path·별칭·reparse·hardlink, namespace 안의 unknown DB 후보를 검사한다. source directory identity 공유는 허용하고 main/WAL/SHM 파일 identity의 재사용은 거절한다. 원격 ThreadStore는 local proof가 없으므로 지원 완료로 수용하지 않는다.

`ctxhop/complete`의 단일 `dbObservation`을 `storeObservation`으로 바꾼다. 외부 complete는 아래 binding의 7개 필드와 `storeObservation`을 같은 최상위 object에 갖는다. accept/activate 요청은 같은 7개 binding 필드만 갖는다. 기존 6개 필드의 값·검증 규칙을 유지하고 필수 `contractVersion`을 추가한다.

| 외부 binding 필드 | v2 규칙 |
|---|---|
| contractVersion | exact JSON integer 2; 누락/null/문자열/bool/1 거절 |
| requestNonce | prepare와 같은 요청 nonce |
| processNonce | 같은 prepared process incarnation nonce |
| snapshotId | 현재 projection의 snapshot ID |
| generation | 현재 projection의 세대 정수 |
| projectionDigest | 현재 projection의 digest |
| operation | 승인된 같은 operation |

prepare projection의 `contractVersion`도 2다. 기존 projection 필드에 `proofTargets`, `storeObservationDigest`, `storeProof`를 추가하고 기존 `acquisitionId`를 유지한다. `proofTargets`는 partial/completed 모두 실제 8개 descriptor이며, partial의 `acquisitionId`/`storeObservationDigest`/`storeProof`는 3개 모두 explicit null이다. completed의 3개 값은 엔진이 직접 검사한 같은 `storeObservation`과 typed proof에 결속한다. `validateStoreBindingsV2` 같은 내부 함수의 `{acquisitionId,storeObservationDigest,storeProof}` 부분 object는 이 projection의 3개 필드만 검사하며 외부 7개 binding을 대신하지 않는다. unknown/duplicate key, 잘못된 null/type/순서/kind, 누락·추가 원소는 거절한다. v1 fixture와 decoder는 과거 시험 근거로 분리할 수 있으나 production 요청의 fallback으로 연결하지 않는다.

```json
{
  "schemaVersion": 2,
  "acquisitionId": "32 lower-case hex",
  "sourceRoot": {
    "directory": "actual canonical original sqlite home",
    "directoryIdentity": "24 lower-case hex"
  },
  "privateRoot": {
    "directory": "absolute newly owned directory",
    "directoryIdentity": "24 lower-case hex"
  },
  "stores": [
    {
      "kind": "state",
      "dbPath": "actual canonical source state_5.sqlite",
      "present": true,
      "acquisition": {
        "schemaVersion": 1,
        "acquisitionId": "aggregate acquisitionId",
        "source": {
          "directoryIdentity": "24 lower-case hex",
          "main": {"identity":"24 lower-case hex","size":4096,"sha256":"64 lower-case hex"},
          "wal": null,
          "shm": null
        },
        "private": {
          "directory": "privateRoot/state",
          "directoryIdentity": "24 lower-case hex",
          "main": {"identity":"24 lower-case hex","size":4096,"sha256":"same source main sha256"},
          "wal": null
        },
        "rollbackJournalAbsent": true
      }
    },
    {"kind":"logs","dbPath":"actual canonical logs_2.sqlite","present":false,"acquisition":null}
  ]
}
```

예제는 2개 store만 보이지만 실제 요청은 정해진 순서의 8개 entry가 필수다.

`present:false`는 main/WAL/SHM/rollback-journal 4개 이름 모두를 양쪽에서 직접 확인한 부재다. orphan sidecar가 하나라도 있으면 absent로 인정하지 않고 unknown으로 멈춘다. 부재 store도 source ancestor/directory handle을 유지한다. 기존 홈의 member complete에서 state 부재는 거절하며, 새 홈 bootstrap만 기존 별도 계약으로 처리한다.

sourceRoot는 prepare의 normalSqliteHome/operationSqliteHome와 같은 실제 canonical root여야 한다. absent entry의 부모도 이 root로 직접 확인하고, present acquisition의 source.directoryIdentity도 sourceRoot.directoryIdentity와 같아야 한다. sourceRoot와 privateRoot는 경로·identity가 다르며 서로 하위가 아니다. 모든 private kind directory identity와 source/private 파일 identity는 서로 다르다. ancestor identity는 공유 가능하며 중복 handle은 집합 소유자가 관리한다.

각 present acquisition은 기존 v1의 owner·protected DACL·Win32 identity·source/private 불일치·immutable main/WAL·bounded 생성 sidecar 검사를 그대로 사용한다. privateRoot 바로 아래에는 present kind의 전용 directory만 만들고, 그 안에는 해당 store의 알려진 main/WAL/SHM만 허용한다. Rust도 root/kind/canonical filename을 직접 대조하며, 여러 entry에 같은 private file을 지정해서는 안 된다. absent kind의 private directory와 unknown entry는 만들지 않는다. manifest/receipt는 SQLite copy directory 밖의 runner-owned 출력에 둔다.

source/private 전체 파일 크기는 overflow를 검사한다. store별 기존 limit과 함께 main+존재 WAL의 8store 합계도 1GiB 이하여야 한다. SHM은 기존 bounded limit을 지킨다. 중복 본문 hash 필드를 추가하지 않으며 nested acquisition이 유일한 file vector다. 전체 manifest를 기존 safe_digest(재귀 key 오름차순, array 순서 유지, UTF-8 compact JSON, unknown field 거절)로 hash하고 projection에 `acquisitionId`와 `storeObservationDigest`를 결속한다. Go/Rust의 비ASCII·escape·null을 포함한 공통 fixture로 digest 일치를 실측한다.

1GiB는 source main+존재 WAL을 한 번만 합산하며 동일 private copy를 다시 합산하지 않는다. SHM은 각16MiB/전체128MiB다. store entry8, source 파일 최대24, private 최초 복사파일 최대16/생성sidecar 포함 최대24, kind directory 최대8이다. 크기는 unsigned metadata와 checked limit-minus-total로 첫 copy 전에 판정한다. 승인 member 최대2000과 기존16MiB frame limit을 유지한다. count는 비음수 exact i64 정수이며 overflow/누락/중복은 unknown이다. query row/본문 버퍼와 timeout은 기존 bounded 값을 줄이지 않으며 커진 summary가 frame 한도를 넘으면 차단한다.

digest 전용 직렬화는 Go json.Marshal의 HTML/U+2028/U+2029 자동 escape 차이를 그대로 사용하지 않는다. Rust safe_digest와 일치하는 공통 golden bytes를 한 번 동결하고 경로의 한글·emoji·<>&·U+2028/U+2029·따옴표·역슬래시·null·정수·key순서를 양쪽에서 검사한다. wire transport의 일반 JSON escaping을 바꾸는 것과 digest bytes를 혼동하지 않는다. partial prepare의 acquisitionId/storeObservationDigest/storeProof는 모두 explicit null, completed는 모두 실제 internal proof에 결속된 값이다.

## 전체 핸들 획득·읽기·종료

1. exact prepared process를 Job/image/incarnation/channel에 결속해 guard하고 canonical 8 descriptors와 source namespace를 확정한다.
2. **어느 store의 첫 byte도 읽기 전에** 전체 store의 ancestor/directory/main/존재 WAL/존재 SHM raw handles를 획득하고 모든 부재 이름을 직접 확인한다. 기존 v1의 READ/share-READ와 directory DELETE deny를 사용한다. 중간 획득 실패 때는 획득한 handle을 모두 drain하고 복사 시작0으로 실패한다.
3. 모든 source handles를 유지한 상태에서 privateRoot와 kind directories의 ACL/identity를 먼저 확인하고 CREATE_NEW로 main/존재 WAL을 복사한다. source SHM은 읽고 hash할 뿐 복사하지 않는다. 전체 copy finalized 이전에는 Go/Rust SQLite reader를 시작하지 않는다.
4. Go는 하나의 집합 proof 처리에서 present store마다 최대1의 private readonly connection을 연다. Rust도 같은 private files를 store마다 최대1의 readonly pool(create_if_missing=false/query_only)로 읽어 전체 member의 SQL/typed decoder를 공유한다. state canonical decoder는 기존 추출 함수를 재사용하며 runtime initializer는 호출하지 않는다.
5. success/error/cancel/decoder error 모두에서 전체 private readers의 close를 await한다. 일부 성공을 completed generation으로 만들지 않는다. source/private identity/bytes/absence와 privateRoot namespace를 재검증한 후에만 Rust가 completed generation과 aggregate binding을 반환한다.
6. Go는 전체 reader 종료와 aggregate source/private 재검증→전체 private owned cleanup→전체 source handle release→fresh guard/input/config/auth/rollout/source 전체 vector 재검증→accept/activate 순서를 지킨다. close/cleanup 실패를 성공으로 숨기지 않으며 unknown entry는 보존하고 멈춘다.

전체 마지막 freshness sweep도 새 전체 source handle을 먼저 획득한 뒤 첫 hash byte를 읽는다. Rust도 validate_acquisition을 store마다 완결 호출하는 대신 native pin-only 단계로 전체 source/root/private handle을 얻은 뒤 전체 measure/check를 한다. metadata-only pin에는 SHM hash도 없다. cleanup은 전체 namespace/known identity를 먼저 검사하고 전체 private 삭제 뒤 집합이 source leases를 해제한다. store별 Close(true) loop로 source를 먼저 푸는 방식은 금지한다. explicit drain 결과를 모으며 Drop만으로 close 성공을 선언하지 않는다. private cleanup 이후 accept는 보유한 completed proof와 source-only freshness를 소비하고 private DB를 다시 열지 않는다.

이는 전체 raw handle 획득 후의 frozen filesystem vector이며 과거 cross-store transaction을 증명하지 않는다. source absent name의 절대 lock과 해제→canonical first write의 경쟁 배제도 보장하지 않는다. 배치 전 block, 배치 후 pending/명시적 recover라는 기존 실패 규칙을 유지한다.

## schema와 참조 proof

store별 고정 LF vendor source를 명시한 provider builder profile로 변환한 migration bytes, 성공/version/checksum, sqlite_master 전체 object(type/name/table/sql), table_xinfo, FK/index/trigger/view를 엄격하게 확인한다. 현재 profile은 CRLF이며 고정 normalEngineSha256과 결속한다. Git 원문이 CRLF라는 뜻이 아니다. root builder `21e120fa`의 LF→CRLF 함수 검증과 기존 단회 receipt의 state58 CRLF checksum 일치는 확보했지만 실제 전체 엔진 build/runtime 호환은 별도 필수 gate다. LF/다른 engine profile을 검증 없이 관용 비교로 수용하지 않는다. 미래 migration/unknown schema/미해석 typed key를 정상 구조로 인정하지 않는다. board는 실제 raw SCHEMA를 같은 고정 vendor에 결속하며 가상의 migration table을 요구하지 않는다. winsqlite3와 bundled SQLite의 차이는 같은 synthetic files에서 실측한다.

M=승인 member IDs, R=그 canonical immutable rollout IDs, Q=그 root SessionIds다. 승인 plan/journal의 M→R→Q mapping은 실제 strict file inventory와 별도로 검증·보유한다. 부재 파일에 path를 만들어 mapping 근거로 쓰지 않는다. query는 bind parameters를 사용하며 본문·비밀·로그 내용을 wire로 내보내지 않는다. 필요한 내부 typed 행/digest는 engine이 보유하고 외부 summary는 store/member/relationClass/분류별 count/unknownReason으로 제한한다.

| store | 필수 relation |
|---|---|
| state | threads/rollout_path, 전체 threads의 typed SessionSource parent, spawn edges 양끝, attachments/dynamic_tools, project/section, migration cursor/skipped paths, active+archived의 strict rollout structural references |
| logs | logs.thread_id IN M. process_uuid만으로 owner를 인정하지 않음 |
| goals | thread_goals와 thread_goal_continuation_deferrals의 thread_id IN M |
| memories/V2 각각 | stage1_outputs.thread_id IN M, jobs(kind=memory_stage1 AND job_key IN M), 모든 kind의 worker_id IN M. unknown kind의 대상 job_key는 unknown |
| queue | queued_items.thread_id IN M、queued_thread_revisions.thread_id IN M |
| threadHistory | thread_turns/thread_items/thread_realtime_items/thread_history_projection_state의 thread_id IN M∪R |
| agentMessageBoard | 5tables의 board IN Q, subscriptions/opt_outs의 agent IN M, posts.request_id의 typed thread prefix IN M. 대상 board의 외부 agent/caller 관계도 확인 |

typed graph는 참조의 양끝을 확인한다. target row만 EXISTS로 확인해 외부 agent/worker/outside parent를 놓치지 않는다. board postUUID와 ThreadId를 혼동하지 않으며 malformed key/unknown caller prefix/unknown source는 unknown이다. 자유문 UUID의 LIKE 검색은 대안이 아니다. opaque attachment/tool semantics는 기존 target presence 거절을 유지한다. RolloutReferenceIndex의 parse-error skip을 부재 증명에 사용하지 않고 공유 parser의 strict S4 proof가 unreadable/malformed/duplicate를 보유해 실패한다.

file proof에는 sessions/archived_sessions의 alternate/immutable/compressed 파일뿐 아니라 `rollout-migrations/<ThreadId>.pending`와 rollout 옆 `.<filename>.paginated.tmp`, `.decompressed.tmp`, `.paginated.zst.tmp`도 포함한다. pending/staging은 passive가 아니다. 대상이나 startup 효과를 불명확하게 만드는 pending/unknown recovery namespace는 migrationRecoveryUnknown으로 멈추고 조사 중 지우지 않는다. skip-index의 parse-error/unknown name을 부재로 처리하지 않는다. M은 root를 포함하는 승인 bundle이며 Q의 root SessionId가 M 밖인 부분 child-only bundle은 기존 family admission 기준과 대조해 미검증이면 거절한다.

completed projection의 `storeProof`는 `{schemaVersion:2, observationDigest, members:[{memberId, relations:[{kind, relationClass, counts:{active,internal,externalIncoming,externalOutgoing,sharedGlobal,passive}}]}]}` summary다. members는 승인 plan 순서, relation은 `engine/store-proof-v2-catalog.json`의 store/class 순서로 고정하며 29개 class와 6개 scope의 0도 명시한다. absent store도 검증된 부재의 0 summary를 포함한다. field/class/scope 누락·추가·중복, 음수·소수·i64 overflow는 unknown이다. JSON object key 순서는 digest에서 정규화하고 array 순서는 바꾸지 않는다.

방향은 sessionSource child→parent, spawnEdge parent→child, memory job owner(job_key)→worker, board root→agent/caller다. 외부 owner→M endpoint는 externalIncoming, M owner→외부 endpoint는 externalOutgoing, 양끝 M은 internal이다. edge는 각 관련 member에 한 번씩 귀속하며 M/R의 UUID가 같아도 domain을 합치지 않는다. typed target worker 등으로 관측한 globalJob은 sharedGlobal로 승인 member 전체에 귀속한다. 무관한 global 행을 새 ID collision으로 만들지 않으며 정상 runtime의 별도 global reset 효과는 독립 gate에서 검사한다. revision/cursor/deletedBoard의 passive 분류가 import collision을 제거하지 않는다. 내부 proof는 parsed row/key/schema/rollout uncertainty도 보유한다. summary 자체는 caller의 ownership 선언이나 삭제 허가가 아니다.

`engine/store-proof-v2-golden.json`의 inputJson/canonicalUtf8/SHA256은 숫자 precision을 보존하는 digest 전용 fixture다. 5개 case에 한글·emoji·HTML 문자·U+2028/U+2029·control escape·null·array순서·reordered keys·i64 최대값을 포함한다. 실제 Go/Rust 실행 일치 전까지 golden 생성 자체를 backend 수용으로 부르지 않는다.

## operation별 사용과 미해결 사항

- prepare-only plan/bootstrap은 SQLite 읽기0이며 acquisitionId/storeObservationDigest/storeProof는 null이다. plan의 member ID 확인만으로 DB 부재를 증명하지 않는다. import의 placing 전 fresh complete에서 아래 새 ID 조건을 반드시 증명한다.
- import의 새 ID는 file/state/structure와 8store 전체의 대상 durable relation이0이어야 한다. unrelated store 행은 허용한다. revision/cursor/deleted_boards도 새 ID collision에서 빠뜨리지 않는다.
- cold/reference는 기존 target을 읽는 proof이므로 target relation0을 일괄 요구하지 않는다. metadata/prefix/settings/lineage와 외부 relation을 검증하고 분류 불가 부작용 후보는 block한다. 대상 logs/history 등이 있다는 이유만으로 새 충돌이나 삭제 권한을 인정하지 않는다. 읽기 context 승인을 aux 행 삭제 승인으로 전용하지 않는다. 초기화/cleanup의 다른 행 효과는 실제 protected runtime gate와 fixture로 별도 검증한다.
- rollback-check는 writable runtime을 열지 않고 journal의 M/prefix/settings와 전체 proof를 읽어 삭제 가능성 또는 needs_attention만 반환한다. 관측을 얻기 위해 canonical repair/migrate/delete를 실행하지 않는다.
- 명시적 rollback은 실제 canonical delete subtree와 승인 M의 완전 일치, bundle 밖 reverse/worker/board/history relation0, attachment/tool0, journal 소유/prefix/settings 일치를 삭제 직전에 확인한다. caller own=true/processUUID만으로 허가하지 않는다. target aux 행의 소유/정상 cleanup이 증명되기 전에는 needs_attention을 유지한다. 추가 trusted mutation provenance 설계는 별도 검토 대상이며 이 wire 확장으로 완료됐다고 표현하지 않는다.
- rollbackAbsent는 **전체 file/state/8store 대상 durable relation0**이라는 v1 조건을 유지한다. queue revision/board deleted tombstone/migration cursor를 몰래 제외하지 않는다. marker ID에는 delete를 보내지 않는다. canonical delete 뒤 passive tombstone이 남으면 rollbackAbsent로 수용하지 않는다. 아래 rollbackRetained의 별도 조건을 실제 증명한 경우만 원본 보존 terminal 정리를 허용하며, 그 밖에는 pending/needs_attention을 유지한다. 자동 대화 삭제 권한은 늘어나지 않는다.

### rollbackRetained: 원본을 보존하는 별도 terminal marker

root는 설계 검토 `r45-store-set-design-review.md`의 조건부 후보를 구현 기준으로 채택한다. rollbackAbsent의 all durable refs0 의미는 바꾸지 않는다. rollbackRetained는 승인된 명시적 recover/retry의 소유 journal과 M을 검사하고, 대화 file/state 및 모든 active/foreign relation이0인데 아래 고정 passive 흔적만 남은 경우만 허용한다. 과거에 누가 그 행을 썼는지는 새 삭제 권한으로 추정하지 않는다. **추가 원본 쓰기·삭제·runtime activate·RPC resume/delete는0**이며 typed readonly proof 종료 뒤 ctxhop의 소유 journal/stage/ref 정리만 한다.

| retainedKinds | 실제 의미와 조건 |
|---|---|
| agentMessageBoard.deletedBoard | Q의 deleted_boards만 존재. board active4tables·외부 agent/caller0. future board write를 거절하는 tombstone을 그대로 유지 |
| queue.revision | M의 queued_thread_revisions만 존재. target queued_items0, live thread/runtime0, 정상 양수 정수 revision과 canonical triggers 확인 |
| state.migrationCursor | migration_id=`legacy_to_paginated_v1`의 완전하고 정상 범위인 timestamp+M ID cursor만 존재. 해당 파일/state/skipped/pending/staging0. shared startup scan frontier를 그대로 유지 |

finished memory jobs/worker/global consolidation, goals/deferrals, logs, history rows, skipped rollout, unknown migration id/schema/key는 passive allowlist에 넣지 않는다. all active/foreign/unknown0을 실제 확인할 수 없으면 pending/needs_attention이다. counts0인 class를 retainedKinds에 넣지 않는다. marker와 predicate digest는 pinned engine가 직접 발급/보유하며 caller own=true는 사용하지 않는다. 새 ID import는 이 passive 흔적도 계속 collision으로 거절한다.

context phase=`rollbackRetained`는 memberId/ownerId에 결속하고 rolloutSha256/settingsDigest는 null이다. resume/name/archive/delete 권한이 없고 activate가 거절된다. 모든 member가 rollbackAbsent/rollbackRetained일 때 Go는 complete proof의 reader/cleanup/source-release/freshness를 마치고 abort/EOF로 준비 엔진을 종료해 소유 Job0를 확인한 후 journal 정리만 한다. present member와 혼합된 경우에는 marker를 delete/resume 대상에서 제외하며 실제 canonical delete subtree는 fresh proven present target 집합과 정확히 같아야 한다. 혼합 RPC gate는 별도 fixture를 통과하기 전 차단한다.

이 경로의 journal/result는 `absenceKind:retained`, nonempty `retainedKinds`와 원문 안내를 보존한다: “대화와 활성·외부 참조가 없음을 확인했습니다. 엔진의 삭제 표시와 순회 기록은 보존했습니다.” rolled_back의 뜻은 승인 묶음 대화 부재와 소유 복구 기록 정리 완료이며 원본 byte 복원·모든 durable ref0·흔적 생성 주체 증명이 아니다. 기존 소비자가 이 뜻을 다르게 해석하면 UI/API를 같은 변경으로 갱신하기 전 terminal 성공을 반환하지 않는다. cleanup/cancel/입력 변경/replay 실패는 pending이다. 다른 source 효과가 이미 있었을 수 있으며 이 marker가 과거 효과를0으로 만들었다고 보고하지 않는다.

## 구현 소유권과 필요한 증거

root는 이 계약/policy 판단/integration을 소유한다. helper1은 기존 P 소스의 canonical descriptor/readonly proof/shared decoders/strict rollout uncertainty/v2 wire/projection을 소유하고 기존 V2/settings/activation 및 target 실행과 직접 직렬화한다. helper2는 R impl/codex의 aggregate raw acquisition/schema/typed relations/wire/projection/freshness/cleanup을 소유한다. helper3는 기존 Test-PrestartEngine runner와 새 synthetic store fixtures/근거 출력을 소유하며 원래 schema export는 다시 실행하지 않는다. 합성 보조 schema seal은 실제 canonical migrator/board SCHEMA와 같은 고정 profile로 새 owned seed를 생성한 원자료에만 근거한다. 새 namespace writer/reader는 실행 전 소유권을 결속한다.

v1 same-copy 8case는 기존 고정 후보로 완료하며 fixture 수정이 필요한 실패는 새 pin과 새 case에서만 검사한다. v2는 새 합성 DB만 사용해 unrelated 정상8stores 수용, store별 새 ID 충돌, orphan/미래 schema/unknown namespace, 역방향 worker/board agent/caller, malformed rollout, 전체 handle-before-byte, 중간 acquire/copy/query/close/cleanup 실패, private alias/unknown directory, schema/hash/digest/null의 Go·Rust 일치를 검증한다. root/auth/model/config 제한과 actual engine admission이 해제됐다는 뜻은 아니다. 실제 activation/cold/V2/manual rollback/retry 및 최종 fresh 독립 감사는 별도 미완료 필수 gate다.
