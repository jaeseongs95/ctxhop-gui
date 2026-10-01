# ScopeSafety 독립 검토

## 1. Executive Verdict

검증된 original M→Q mapping의 matching M들과 직접 typed ThreadId endpoint의 union을 읽기 relation 귀속에 사용하는 안은 조건부로 타당하다. UUID 값의 Q==M equality를 canonical ownership invariant로 보기는 어렵다. 다만 Q∈M 검사를 지우는 것만으로 family admission 또는 삭제 안전성을 충족하지 않는다. 기존 canonical 삭제 caller는 삭제 ThreadId를 SessionId로 변환한다. 따라서 읽기 귀속 변경과 실제 삭제 footprint 검증은 별도 gate여야 한다.

이 보고서는 설계 검토다. 제품 PASS, 실행 handoff, 원본 삭제 승인 또는 패널 전체 합의를 발급하지 않는다. source/DB/test/engine 실행과 source 변경은 하지 않았다.

## 2. Consensus Proposal

개별 reviewer의 조건부 후보이며 panel consensus는 판단하지 않는다.

승인 순서를 가진 immutable mapping q(m)를 보유하고, relation r의 board b와 optional typed endpoint e에 대해 귀속 집합을 `T(r)={m∈M | q(m)=b} ∪ {m∈M | m=e}`로 정한다. 이 집합을 승인 member 순서로 순회하고 각 member/class/scope에 해당 원 relation을 한 번 센다. owner 쪽은 boardRoot/SessionId domain에서 q(m)로만 판단한다. body UUID, resource UUID, AgentPath, parent/root 추정, 숫자가 같은 다른 M은 matching 근거가 아니다.

scope는 현행 typed 분류를 유지한다. b∈Q와 e∈M이면 internal, b∈Q와 e∉M이면 externalOutgoing, b∉Q와 e∈M이면 externalIncoming, b∈Q이고 endpoint가 없는 channel이면 active, b∈Q의 deletedBoard이면 passive다. shared Q라고 board relation을 sharedGlobal로 바꾸지 않는다. sharedGlobal은 별도 globalJob 의미다.

mapping q는 원 approval full source와 불변 summary/digest로 독립 검증한 값이어야 한다. current inventory 값으로 덮어쓰지 않는다. raw Q∉M을 받아들이더라도 실제 family/subtree 범위가 승인 M에 정확히 맞고 unknown/foreign이 없다는 별도 근거가 필요하다. 그 근거가 없으면 needs_attention이다.

global count는 원 relation record당 한 번이다. 여러 member에 fan-out된 count의 합계를 global count로 쓰지 않는다. 반대로 compact relation의 board/endpoint/resource가 같다는 이유로 서로 다른 channel 같은 원 행을 하나로 합치지도 않는다.

## 3. Strong Consensus

다른 reviewer를 읽지 않아 강한 합의는 주장하지 않는다. 이 역할의 관측과 판단은 다음 material claims다. `P`는 bc0e04c6f0bca377bef07e3fa0c3c6ce3784096b, `R`은 3a435d471963e86201912d9abcb6b6d1c5617c18의 frozen Git object다. 아래 locator는 각 commit의 경로와 one-based line이다.

### S-1 — 현행 equality는 검증된 per-member Q mapping을 귀속에 쓰지 않는다

관측: P:codex-rs/ext/agent-message-board/src/local/prestart_proof.rs:107–114는 모든 root_session_id 값이 member ID 집합에 있어야 한다. :128–146은 Q set만 저장하고, :49–62는 board가 Q set에 있고 SessionId::from(member_id)==board인 멤버 또는 직접 endpoint를 반환한다. R:impl/codex/store_relations_windows.go:41–64도 Q∈M을 검사하며, R:impl/codex/store_projection_windows.go:85–96의 boardRoot touches는 key.ID==member.ID다.

추론/반례: M={A,B}, q(A)=B, q(B)=A라면 Q∈M guard는 통과하지만 board B의 endpoint 없는 channel/deletedBoard가 B에 귀속되고 A에는 귀속되지 않는다. 원 mapping owner는 A다. 이것은 Q set containment가 mapping 정확성을 대신하지 못함을 보인다. 이 tuple이 실제 제품 fixture에서 승인 가능한지는 별도 family evidence가 필요하며 여기서는 실행하지 않았다.

### S-2 — canonical source는 M과 Q가 다른 값이고 여러 M이 Q를 공유하는 경로를 가진다

관측: P:codex-rs/protocol/src/protocol.rs:3130–3140은 SessionId와 ThreadId/parent를 별도 필드로 보유한다. :3243–3268의 SessionMetaLine decoder는 session_id 키가 없을 때만 id를 삽입하며 Q==M validation은 없다. P:codex-rs/core/src/session/session.rs:894–915는 resumed metadata Q를 선택하거나 non-root agent에서 controller.identity를 사용한다. 같은 controller에 속한 서로 다른 child ThreadId는 같은 session identity를 사용할 수 있다. :1017–1026은 선택한 Q와 M을 별도로 CreateThreadParams에 전달한다. :1648–1649의 session store identity를 P:codex-rs/ext/agent-message-board/src/extension.rs:50–58이 board SessionId로 읽는다. P:codex-rs/core/src/agent_message_board.rs:64,:85–89는 이 Q로 durable board를 열고 actor의 session identity를 비교한다.

관측된 범위: canonical 실행 경로에 공유 Q가 허용된다는 근거다. q(rootA)=X∉M인 임의 원본 bundle의 admission 성공 또는 임의 외부 데이터의 정당성까지 증명하지 않는다. session.rs:903–906의 legacy child runtime filtering은 원 approval의 Q를 parent/root Q로 바꾸라는 근거가 아니다.

### S-3 — shared Q의 endpoint 없는 relation 누락은 member별 false absence 위험이다

관측: P:codex-rs/ext/agent-message-board/src/local/prestart_proof.rs:155–165는 Q의 tombstone을 passive로 record한다. :49–62의 equality 귀속은 q(m)를 보지 않는다. R:impl/codex/store_projection_windows.go:143–158은 touches에 매칭되지 않은 relation을 실패 처리하고, 매칭된 member에만 count를 증가시킨다.

추론/반례: M={A,B}, q(A)=q(B)=A에서 endpoint 없는 board A channel/tombstone은 현재 A에만 귀속된다. B의 per-member board summary가 0인 사실은 B의 verified Q에 durable relation이 없음을 뜻하지 않는다. q(A)=q(B)=X∉M을 guard 제거만으로 허용하면 endpoint 없는 relation은 Rust에서 귀속 집합이 비고 Go projection은 unmatched error가 된다. guard 제거와 귀속 변경을 분리해 배포할 수 없다.

### S-4 — board membership과 endpoint membership의 양쪽 검사는 유지해야 한다

관측: P:codex-rs/ext/agent-message-board/src/local/prestart_proof.rs:132–140은 approved board의 foreign endpoint를 externalOutgoing, foreign board의 approved endpoint를 externalIncoming으로 기록한다. :5–6,:23–29는 resource/author/board/endpoint domain을 구별한다. R:impl/codex/store_relations_windows.go:484–534는 request_id prefix/agent를 typed thread endpoint로 읽고, R:impl/codex/store_projection_windows.go:129–142는 boardRoot/typed thread domain 및 sharedGlobal 사용을 제한한다.

추론/반례: q(A)=q(B)=X인 board X→foreign F relation은 A와 B 모두의 externalOutgoing이어야 한다. foreign board Z→A는 A의 externalIncoming이며 Z의 숫자가 B와 같아도 B는 owner로 추가되지 않는다. body/resource UUID가 B인 경우에도 B를 추가하지 않는다. 외부 관계를 내부로 바꾸거나 외부 owner를 approved member로 승격하면 삭제 중단 조건을 지우는 결과가 된다.

### S-5 — global unique counting과 member union counting은 별도량이다

관측: P:codex-rs/ext/agent-message-board/src/local/prestart_proof.rs:64–87은 원 record마다 global counts를 한 번 증가시키고 relation을 한 번 push한다. R:impl/codex/store_projection_windows.go:143–155는 member마다 owner OR endpoint 조건을 적용해 한 번 증가시킨다. P:codex-rs/ext/agent-message-board/src/local/prestart_proof/tests.rs:89–106은 global internal post=1인 동시에 두 member 귀속을 명시한다. R:impl/codex/store_relations_windows_test.go:100–111도 양 끝 member의 internal post count=1을 기대한다.

추론/반례: q(A)=q(B)=X이고 X→A post 하나면 global post/internal=1, A=1, B=1이다. A는 board mapping과 endpoint 두 이유로 닿아도 2가 아니다. 다른 channel 이름의 원 행 두 개는 같은 compact board/endpoint/resource라도 global channel=2, 각 matching member=2다. fan-out sum 또는 compact tuple dedup은 각각 과다/과소 count를 만든다. member order와 array order는 유지하고 변경된 member count는 digest에 반영해야 한다.

### S-6 — 기존 회귀의 domain 보호는 보존되지만 일부 귀속 기대값은 의도적으로 바뀐다

관측: P:codex-rs/ext/agent-message-board/src/local/prestart_proof/tests.rs:191–203은 child-only Q∉M을 unknown으로 기대한다. :225–269는 board UUID가 M에 있지만 Q 밖일 때 approved endpoint만 귀속한다. R:impl/codex/store_domain_cancel_windows_test.go:14–58은 같은 domain 반례와 잘못된 thread owner rejection을 검사한다. R:impl/codex/store_relations_windows_test.go:21–27은 root/child가 root Q를 공유하는 targets다. :49–52의 mock은 active 행과 deletedBoard를 동시에 넣고 :84–86은 counts를 검사한다.

추론: M\\Q board domain 보호는 새 mapping 귀속에서도 유지된다. root Q에 endpoint가 없는 channel, root 자신 endpoint인 relation, foreign endpoint relation, tombstone은 shared child의 새 per-member count가 증가한다. 기존의 endpoint child인 internal post는 이미 root와 child 양쪽에 count되므로 그대로다. Q∉M fixture는 숫자 inequality 전체 거절에서, 미검증 partial family 거절과 독립 검증된 raw mapping 수용을 구별하도록 바뀌어야 한다. Go mock counts fixture는 Rust의 deleted+active key invariant를 검증하는 실제 DB fixture가 아니므로 retained safety 증거로 사용할 수 없다.

### S-7 — 실제 삭제 footprint는 Q mapping이 아니라 삭제 ThreadId 값에서 도출된다

관측: P:codex-rs/core/src/thread_manager.rs:463–467은 cleanup thread_ids를 Into::into로 SessionId list로 바꾼다. P:codex-rs/thread-store/src/local/delete_thread.rs:70–79,:99–125는 reference/writer 검사 뒤 cleanup에 실제 삭제 ThreadId list를 넘긴다. P:codex-rs/ext/agent-message-board/src/local/lifecycle.rs:67–84는 각 받은 값의 board에 tombstone을 쓰고 four active tables를 삭제한다. :20–23은 child ID가 parent board와 같지 않으며 feature와 무관하게 cleanup한다고 명시한다. P:codex-rs/core/src/thread_manager.rs:998–1033의 subtree discovery는 spawn descendants/live subtree로 구성하고 shared Q에서 member를 찾지 않는다.

추론/반례: 승인 M={A,B}, q(A)=q(B)=X∉M이면 canonical deletion의 board footprint D={SessionId(A),SessionId(B)}이고 Q={X}다. reader를 broad하게 바꿔도 X의 active rows는 cleanup에서 남을 수 있다. 동시에 A/B 숫자의 다른 board가 존재하면 그 행을 지울 수 있다. 기존 M={root,child}, Q={root}에서도 child 숫자 board∉Q의 channel은 reader ownership상 unrelated지만 canonical cleanup D에는 들어갈 수 있다. 기존 domain test의 reader filtering 성공을 삭제 안전성으로 바꾸면 안 된다.

필수 gate: fresh proven delete subtree와 승인 present M의 정확한 일치 외에, canonical D의 실제 board effects를 따로 검증해야 한다. D\\Q의 외부/unknown board를 approved ownership으로 자동 편입하지 말고 unsafe effect로 중단한다. Q\\D active data가 cleanup되지 않는 경우 정상 cleanup이 입증되지 않았으므로 삭제 성공/absence를 약속하지 않는다. reader 안에서 delete_boards를 Q로 치환하거나 board의 다른 known M을 subtree에 추가하는 안은 원 scope 확대다.

### S-8 — retained tombstone은 durable collision이며 원본 보존 terminal 경로만 허용한다

계약 관측: SHA가 확인된 redesign/s4-prestart-store-set-v2.md:140,:143–156은 import passive 포함 collision, rollbackAbsent all durable0, exact3 passive allowlist와 active/foreign/unknown0를 요구한다. :158은 all-marker에서 engine 종료 뒤 owned journal 정리만 하며 mixed는 별도 fixture 전 차단한다. redesign/s4-approval-evidence-v1.md:68은 같은 조건을 재확인한다. P:codex-rs/ext/agent-message-board/src/local/lifecycle.rs:97–107은 tombstone이 future write를 거절함을 보인다.

추론/반례: shared X tombstone 하나를 A/B 각 passive=1로 귀속해도 원 tombstone은 하나이며 그대로 보존한다. 둘의 import collision은 모두 차단한다. 이것을 absence 또는 새 삭제 authority로 해석하지 않는다. tombstone+active rows, 외부 endpoint, 잘못된 key/unknown schema, source mapping uncertainty가 있으면 retained를 발급하지 않는다. Q∉M의 원 source가 postdelete에 사라졌다고 actual absence를 근거로 Q=M을 합성하면 false absence가 생긴다.

### S-9 — approved mapping의 inclusion은 board 독점 소유나 foreign member 부재를 증명하지 않는다

관측: P:codex-rs/state/src/prestart_store_proof.rs:203–209는 absent member도 approved mapping에 포함하며 caller authorization 결속을 요구한다. :294–296은 Q를 extra history/thread target set으로 쓰지 않도록 구별한다. redesign/s4-prestart-store-set-v2.md:115,:129,:143은 original mapping, family admission, actual subtree 및 bundle 밖 관계0를 별도 요구한다. redesign/s4-approval-evidence-v1.md:52,:58,:62는 original source Q, summary digest, actual-vs-approved mapping 불변을 요구한다.

추론/반례: q(A)=q(B)=X이고 actual known foreign C도 q(C)=X인 경우, board 행의 endpoint가 A뿐이라 internal이라는 이유로 X가 승인 bundle에 독점 소유됐다고 판단할 수 없다. C를 새 target에 추가하지 않는다. canonical mapping/lineage에 관측된 foreign sharing은 삭제 effects/family gate에서 중단한다. C의 실제 참여 여부가 unknown이면 unknown을 내부 또는 unrelated로 바꾸지 않는다. 반면 Z∉Q이고 endpoint∉M이며 D와도 무관하고 key/schema가 정상인 unrelated board는 새 collision으로 만들지 않는다. foreign relation count와 unknown owner evidence는 같은 개념이 아니다.

## 4. Material Disagreements

후보별 이 역할의 판단이다.

| 후보 | 판단 | scope/delete 위험 |
|---|---|---|
| 현행 Q∈M + numeric Q==M 귀속 | broad 지원 기준으로 불충분 | S-1/S-3의 member false absence, source-valid distinct Q를 숫자 규칙으로 거절 |
| Q∈M guard만 제거 | 거절 | endpoint 없는 relation의 빈 귀속/unmatched 실패를 고치지 못함 |
| raw Q를 parent/rootM으로 정규화 | 거절 | original Q/digest 변경, foreign board를 내부로 바꿀 위험 |
| 검증된 matching M→Q + direct endpoint union | 읽기 후보로 조건부 지지 | S-7 실제 삭제 effects, S-9 foreign sharing을 독립 gate로 유지해야 함 |
| 모든 known Q 공유 member까지 target/subtree 확대 | 거절 | 원 승인 M scope 확대 |
| 공유 Q를 sharedGlobal로 분류 | 거절 | board 내부/외부 방향과 globalJob 의미를 혼동 |
| per-member fan-out 합계로 global count | 거절 | S-5의 relation 중복 집계 |

## 5. Decision by Axis

| 경우 | relation scope/귀속 | 삭제·terminal 조건 |
|---|---|---|
| 검증된 Q∉M | b∈Q 기준으로 scope, matching M 및 직접 e∈M union | 미검증 child-only는 차단. D/Q 불일치 effects는 별도 검증, 삭제 승인0 |
| M={A,B}, q={X,X}, X→A | internal; A,B 각1; global1 | shared Q가 subtree relation을 추가하지 않음 |
| root A→X, child B→Y | X channel은 A, Y channel은 B. X→B post는 A,B union/internal | parent 관계로 Y를 X로 치환0, actual subtree는 독립 확인 |
| q(A)=B, q(B)=Y; board B channel | A만 active; B는 numeric equality로 귀속0 | numeric collision board effects를 별도 검사 |
| approved board X→foreign F | externalOutgoing; X matching M들 | foreign0 실패로 삭제/retained 중단 |
| foreign board Z→A | externalIncoming; A만 | Z 소유·삭제권한0, foreign0 실패 |
| approved X deletedBoard | passive; X matching M들; global tombstone1 | import 차단, absent0, exact retained 원본 보존만 후보 |
| unrelated Z, endpoint도 outside | target relation 귀속 없음 | D와 무관한 정상 row만 unrelated. D에 걸리면 effects 검토 필수 |
| owner/mapping/key unknown | 성공 scope/0 summary로 변환하지 않음 | unknown으로 중단; body/AgentPath/ancestry 추정0 |

## 6. Evidence

case-brief raw SHA256 41EBF797C7186450E8DA096BCB675C966AC724208757752C57133B2CD901D4EC를 직접 확인했다. 다음 계약 raw SHA256도 직접 일치 확인했다.

- redesign/s4-approval-evidence-v1.md: 2132EABCC4D398C02839FEFA2D8A12AAB68024763892F74912001CD1D53DF571
- redesign/s4-prestart-store-set-v2.md: 6C4B86DF0553F3FAD03531D140E2609EC43C5DEAE24528FDD2DA76E09571F161
- redesign/s4-recovery-evidence-v1.md: 72290EE61D0FBCCAFF4F245E280C2306B6CCAEC01847E68E57DFB14BCBD8BCFE

코드 근거는 위 P/R commit에 대한 git show/git grep 출력만 사용했다. current worktree source, 다른 reviewer/Judge 출력, parent/root 대화·선호를 읽지 않았다. 계약에 포함된 이전 panel 경로/판정을 원자료로 따라 읽지 않았다. S-*의 반례는 source 규칙에 적용한 설계 추론이며 테스트 결과가 아니다.

## 7. Required Actions

향후 구현/수용 전에 다음 fixtures가 필요하다. 여기서는 작성하거나 실행하지 않았다.

1. Canonical full source 기반 distinct M/Q와 shared Q: missing session_id fallback, explicit null/empty/invalid rejection, legacy child 원 Q 보존, first own SessionMeta와 later copied SessionMeta 구별, original-vs-actual mismatch 거절. 단순 caller tuple 성공으로 대체하지 않는다.
2. q(A)=q(B)=X에서 channel, post endpoint A/B/foreign, subscription, optOut, tombstone을 각각 검사한다. approved member 순서 변경, owner+endpoint 동일 member 중복0, global1/per-member fan-out을 Go/Rust 같이 비교한다. channel 두 개의 원 행 count 보존도 확인한다.
3. q(A)=B/q(B)=Y와 q(A)=B/q(B)=A 숫자 collision, board M\\Q의 approved endpoint/foreign endpoint/endpoint 없음, resource/body UUID가 M/Q와 같아도 endpoint로 승격0을 확인한다.
4. Actual known foreign C→same X, unknown C owner, foreign board→approved endpoint, approved board→foreign endpoint를 검증한다. 다른 known M을 target/subtree로 편입하지 않고 active/foreign/unknown에서 삭제·retained를 중단하는지 확인한다.
5. Actual canonical delete subtree exact match와 D={SessionId(deleted ThreadId)}/Q effect matrix: D\\Q board data, Q\\D active rows, numeric collisions, feature off, fresh changed inventory, external history/attachment/tool, unknown schema를 확인한다. 실제 caller effects를 확인하기 전 read proof로 delete safe를 주장하지 않는다.
6. Tombstone-only/all-marker retained는 import collision, durable absence 실패, exact allowlist, activate/delete/resume/application RPC0, readonly 종료·Job0, owned journal cleanup만을 확인한다. tombstone+active malformed invariant와 mixed present/marker는 별도 gate로 검사한다.
7. Member/order/count 변화에 따른 approvedMappingDigest/storeProof/projectionDigest의 양 언어 일치, stale old summaries·old wire/pins 거절, present/absent/postdelete/restart에서 원 evidence 유지 조건을 검증한다.

## 8. Optional Optimizations

읽기 후보 구현 시 이미 보유한 approved order와 q(m)를 사용하면 된다. reverse map Q→matching approved M은 선택적 내부 최적화다. 새 ancestry resolver, 전역 known member scan으로 승인 범위 확대, board sharedGlobal class 추가는 이 질문의 해법으로 제안하지 않는다.

## 9. Unresolved

- Q∉M인 완전한 승인 family의 실제 canonical fixture, 정상 startup/cleanup effects와 admission 기준 일치는 여기서 입증하지 않았다. source decoder가 받는 tuple과 deletion-approved family는 구별해야 한다.
- frozen R:impl/codex/store_reader_windows.go:17–19와 store_projection_windows.go:10–12는 callable source proof와 production complete/admission을 구별한다. 해당 reader count를 제품의 현재 실행 gate 완료로 주장하지 않는다. frozen P의 read_prestart_board_proof caller 검색에서는 exported API/tests를 확인했으며 production integration의 실행 완료를 주장하지 않는다.
- shared Q의 approved mapping은 실제로 공유 가능한 source 경로를 가지지만, 저장된 임의 X의 독점 소유/전체 foreign participant 부재는 추가 inventory evidence가 필요하다.
- 삭제 이후 원 source 없이 source Q를 다시 선언할 수 없다. recovery source/evidence lifetime의 실행 충족과 mixed marker gate는 별도 검증 대상이다.
- 요청 모델은 gpt-6.1-sol/high/fork-none이다. actual backend/model/reasoning 선택과 provider 수준 격리는 이 reviewer에서 관측할 수 없으므로 NOT_OBSERVABLE이다. 요구 충족으로 추정하지 않는다.

## 10. Method / Run Summary

역할 ScopeSafety, blind read-only design review, HIGH 질문, adaptive off. 다른 worker를 생성·재위임하거나 peer에 연락하지 않았다. 이 문서 외 파일/source를 변경하지 않았다. 원 userdata/auth/DB/SQLite/Cargo/test/engine/trace를 실행하지 않았다. 수행한 검증은 case brief/계약 SHA256 직접 비교, fixed P/R source 및 test 정의의 직접 읽기, actual board deletion caller와 adjacent local delete/subtree source 확인이다. test 정의의 기대값을 실행 PASS로 보고하지 않는다. 이후 cross/Judge/전체 panel lifecycle과 validator consistency는 Coordinator가 판단할 사항이며 이 문서는 이를 우회하지 않는다.
