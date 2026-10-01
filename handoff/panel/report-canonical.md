# CanonicalSemantics blind 보고서

## 판단과 한계

검증된 per-member M→Q mapping의 같은 Q에 연결된 approved M들에 board relation을 귀속하고, 직접 ThreadId endpoint가 approved M이면 그 member도 union하는 대안을 권고한다. 숫자 UUID가 같은 M 한 명을 board owner로 고르는 현재 equality는 canonical 의미를 보존하지 않는다. Q 공유는 실제 생성·host source로 확인된다. Q∈M은 fresh 정상 root를 포함한 통상 tree에서 성립할 수 있지만, canonical metadata decoder 자체의 불변식도, 모든 저장된 mapping의 불변식도 아니다.

다만 이 권고는 relation 관측·귀속에 관한 조건부 설계 판단이다. Q∉M이나 divergent Q의 모든 runtime 동작, native 삭제의 정확성, 사용자 삭제 권한, 제품 수용 PASS를 발급하지 않는다. 실제 삭제는 Q mapping과 별도로 ThreadId를 SessionId로 변환한다. 귀속 수정만으로 이 효과 차이를 해결했다고 표현하면 안 된다. 원 계약의 family 승인, exact subtree, active/foreign/unknown0, immutable 승인 mapping, freshness·source·digest·retained 조건은 유지해야 한다.

요청은 gpt-6.1-sol/high/fork-none이었다. 실제 backend/model/추론 수준과 외부 격리 실행 여부는 관측 불가이며 추정하지 않는다. brief, 허용 계약, frozen Git source와 실제 test source만 읽었다. source/DB/SQLite/test/Cargo/engine/trace 실행, source 변경, peer output 열람, peer 연락과 재위임은 하지 않았다. 자기 보고서 작성·형식 확인만 수행한다. lifecycle completed/reused validator 모순은 해결되거나 우회됐다고 주장하지 않는다.

## 고정 근거

P = `codex-prestart-r45@bc0e04c6f0bca377bef07e3fa0c3c6ce3784096b`, R = `ctxhop-gui@3a435d471963e86201912d9abcb6b6d1c5617c18`. 아래 P/R locator는 모두 해당 commit의 `git show` 또는 `git grep`으로 직접 확인했다. current worktree source는 근거로 사용하지 않았다. line 번호는 frozen object 기준이다.

raw SHA256을 직접 대조해 brief `41EBF797C7186450E8DA096BCB675C966AC724208757752C57133B2CD901D4EC`, approval 계약 `2132EABCC4D398C02839FEFA2D8A12AAB68024763892F74912001CD1D53DF571`, store-set 계약 `6C4B86DF0553F3FAD03531D140E2609EC43C5DEAE24528FDD2DA76E09571F161`, recovery 계약 `72290EE61D0FBCCAFF4F245E280C2306B6CCAEC01847E68E57DFB14BCBD8BCFE`와 일치함을 확인했다. 계약은 판정할 원 scope이고, 실행 결과의 증거가 아니다.

| Claim | 직접 확인한 사실과 frozen primary locator | 적용 범위 및 추론 한계 |
|---|---|---|
| C-01 | P `codex-rs/protocol/src/session_id.rs:13-30,55-64,88-95`: SessionId는 UUID wrapper, `new()`는 v7, `from_string`은 UUID parse. ThreadId와 변환할 때 같은 UUID를 보존한다. | 변환 API 존재는 모든 Q가 승인 M에 존재한다는 제약이 아니다. typed domain과 값 equality를 구분해야 한다. |
| C-02 | P `codex-rs/protocol/src/protocol.rs:3123-3132,3243-3268`: SessionMeta의 Q는 SessionId, M은 ThreadId. SessionMetaLine은 `session_id` 키가 없을 때만 `id`를 넣는다. C-01의 Deserialize는 문자열 UUID만 받는다. | absent 키만 Q=M fallback이다. explicit null/숫자/empty/invalid UUID는 parse error다. 이 decoder에는 Q∈M, Q==id, ancestry normalize 검사가 없다. persisted canonical source의 Q를 보존하는 근거다. |
| C-03 | P `core/src/session/session.rs:852-866,894-915,931-959`: fresh root는 자기 ThreadId를 SessionId로 변환한다. non-root는 controller identity를 쓴다. resumed metadata Q는 원칙적으로 보존하며 non-root의 Q==own M만 legacy 값으로 걸러 controller identity로 대체한다. Provided controller는 선택된 Q와 identity 일치를 요구한다. | 공유 Q는 실제 생성 규칙이다. fresh root의 Q=M과 모든 persisted Q의 invariant는 다르다. S4 원 source mapping에서 runtime legacy 보정을 복제하면 원 계약 위반이다. |
| C-04 | P `core/src/agent/control.rs:85-125`, `codex-rs/core/src/agent/control/spawn.rs:591-603`: LocalAgentControl은 tree runtime과 Q를 보유하고 child resume에 `self.clone()`을 넘긴다. P `core/src/session/tests.rs:7113-7152`는 child M과 parent Q를 별도로 복원하도록 정의된다. | 동일 Q를 가진 여러 M은 정상 tree 의미다. test source를 읽었으며 실행하지 않았다. X∉M인 모든 archive root 사례가 fresh 생성됐다는 증거는 아니다. |
| C-05 | P `core/src/session/session.rs:1648-1666`, `ext/agent-message-board/src/extension.rs:48-73`: session ExtensionData level은 Q, thread level은 M. factory는 SessionId tree와 ThreadId caller를 별도로 받고 board.identity()==tree를 검사한다. | board namespace는 raw Q에서 유래한다. archive의 role=root나 ancestry에서 Q를 추정하는 추가 경로가 없다. |
| C-06 | P `core/src/agent_message_board.rs:44-65,79-115,128-141,175-179`: local board를 tree Q로 열고 actor 및 notification recipient의 session_id가 tree와 같아야 한다. path resolve는 controller와 실제 SessionSource를 쓴다. root path fallback은 caller==ThreadId(tree)일 때만 된다. P `codex-rs/protocol/src/protocol.rs:2987-2993`: root source의 get_agent_path는 None이다. | shared Q의 board 참여는 정상이다. persisted root M≠Q를 decoder/runtime가 읽는 것과 해당 root가 board tool까지 정상 사용함은 다르다. latter는 root path 확인에서 실패할 수 있다. arbitrary divergent Q를 정상 tree로 과장하지 않는다. |
| C-07 | P `ext/agent-message-board/src/local.rs:194-195,289-295,319-330`: post request_id는 `{caller}:suffix`, board는 self.identity, subscription 대상 agent는 host로 resolve한 ThreadId. SubscriptionTarget::Thread의 root는 top-level post UUID다. P `codex-rs/ext/agent-message-board/src/local/queries.rs:37-40,80-85`: board identity는 SessionId이며 read도 이를 bind한다. | post body/author AgentPath/resource UUID를 M 또는 Q ownership으로 쓰면 안 된다. 문자열 `Thread` 이름이 host ThreadId endpoint라는 뜻도 아니다. |
| C-08 | P `ext/agent-message-board/src/local/prestart_proof.rs:48-62,107-114,127-147`: proof는 Q membership을 approved M set에 강제한다. scope는 board∈Q와 endpoint∈M으로 분류하지만 per-member attribution은 Q 집합 + SessionId(M)==board equality다. | 전자는 새 source-verified mapping을 reader가 불필요하게 좁힌다. 후자는 집합 Q를 알면서 per-member M→Q를 버린다. fixed source의 구현 사실이며 canonical 생성 invariant의 증거가 아니다. |
| C-09 | R `impl/codex/store_relations_windows.go:10-22,41-70,484-537`, `impl/codex/store_projection_windows.go:85-97,129-158`: ID/Root per-member mapping을 이미 보유하지만 Root∈members를 강제하고 boardRoot touches는 key.ID==member.ID다. scope는 roots/endpoint members로 판단한다. | Rust와 Go 모두 같은 좁은 가정을 갖는다. 한쪽만 고치면 per-member counts 및 digest 의미가 어긋난다. R `store_reader_windows.go:17-20`는 이 source API가 production complete/admission에 wired되지 않았다고 명시한다. |
| C-10 | P `codex-rs/state/src/prestart_store_proof.rs:203-249,281-296`: root_session_id라는 ThreadId 필드는 approved vector에 보존되며 같은 Q를 HashSet에 반복 삽입하는 것을 거절하지 않는다. Q는 board proof용이고 history/thread target 추가 set이 아니다. P `app-server/src/prestart_approval_reader.rs:97-114`, `codex-rs/app-server/src/prestart_approval.rs:209-225`: raw source M/parent/Q를 manifest와 exact 대조하고 ordered digest summary에 Q를 포함한다. | Q mapping은 선언만으로 승인되는 것이 아니다. targetQ가 approved M의 검증된 mapping이라는 전제가 필수이며 known unrelated mapping을 target으로 넓히지 않는다. |
| C-11 | P `ext/agent-message-board/src/local/lifecycle.rs:20-28,67-87,97-106`: delete_boards는 받은 SessionId마다 tombstone을 넣고 4 active table 전체를 board key로 삭제한다. child ID는 부모 board와 다르다는 주석과 delayed write 차단이 있다. P `core/src/thread_manager.rs:463-475`: cleanup은 실제 삭제 ThreadIds 각각을 SessionId로 변환한다. P `codex-rs/thread-store/src/local/delete_thread.rs:73-87,116-135`: reference/writer checks 다음 host cleanup, rollout 삭제, state 삭제 순서다. | native cleanup은 per-member canonical Q를 읽지 않는다. Q sharing은 읽기 귀속이고, 실제 삭제 key D는 SessionId(delete ThreadIds)이다. 정상 Q=root M 사례의 root가 board 삭제를 유발한다는 근거는 있으나 root 한 명만 relation을 관측한다는 근거는 아니다. |
| C-12 | P `app-server/src/request_processors/thread_delete.rs:36-55`, `codex-rs/app-server/src/request_processors/thread_processor.rs:1795-1806`, `core/src/thread_manager.rs:998-1033`: delete RPC는 root와 persisted/live spawn descendants를 구하고 실제 IDs를 삭제한다. | Q 일치만으로 subtree를 만들지 않는다. 동일 Q를 공유하는 관련없는 승인·비승인 M을 자동 추가하면 scope 확대다. 원 exact present subtree와 승인 집합 비교를 유지해야 한다. |

## Q의 합법성을 나누어 판단

**공유 Q:** C-03~C-06은 M이 다른 root/child가 같은 Q의 board를 쓰는 실제 규칙을 보여 준다. unique Q나 Q==each M은 invariant가 아니다. `M={A,B}, Q={X,X}`에서 X=A인 정상 fresh root/child는 직접 source로 설명된다. X가 A/B 밖인 경우도 canonical decoder는 수용할 수 있으나, 해당 full source·family가 승인됐는지 및 실제 board/runtime가 사용하는 Q가 같은지는 독립 증거가 필요하다. 숫자만 주어진 사례를 실행 가능한 정상 tree로 선언하지 않는다.

**Q∉M:** complete M→Q mapping을 검증한 reader에 Q∈M을 canonical 타입 조건으로 강제할 근거는 없다. child-only subset에서는 parent의 Q가 subset M 밖에 있을 수 있고, resumed metadata도 arbitrary valid persisted Q를 보존할 수 있다. 하지만 원 store-set 계약은 root를 포함한 approved bundle과 미검증 child-only bundle의 기존 family admission 대조를 요구한다. 따라서 Q membership 검사를 옮기거나 없애더라도 parent/root inclusion, approved scope 및 실제 canonical family 검사는 없애면 안 된다. 새 root를 포함한 정상 fresh local tree에서 Q∉M이 생성되는 fixture는 확인하지 못했다.

**root A→X, child B→Y:** raw mapping을 그대로 보존한다. canonical parse 성공은 ancestry Q 불일치를 자동 해결하거나 runtime 사용·삭제를 허가하지 않는다. board X relation은 A, board Y relation은 B에 mapping으로 귀속하며 직접 endpoint가 각각 다른 approved member라면 그 member를 추가한다. 실제 parent tree/controller/host가 이 Q 조합을 어떻게 다루는지는 fresh proof와 실제 fixture로 판별해야 한다. parent나 role=root를 이용해 Y를 X/A로 고치지 않는다.

**Q가 다른 approved M의 숫자와 같음:** A→B, B→Y이면 board SessionId(B)는 mapping상 A의 board다. B를 ThreadId로 읽어 자동 owner로 만들면 typed-domain alias다. 단, 실제 ThreadId endpoint B가 있으면 B는 endpoint 자격으로 추가된다. native delete B가 SessionId(B)를 만지는 효과는 별도 실제-effect 확인 대상이다.

## 최소 귀속 대안과 반례

관측 대상은 승인 mapping에서만 `targetQ={q(m) | m∈approved M}`로 만들고, 실제 relation r=(board b, optional endpoint e)의 귀속은 다음으로 정의한다.

```
boardMembers(r) = {m in approved M | q(m) == SessionId(b)}
directMembers(r) = {m in approved M | Some(ThreadId(m)) == e}
relationMembers(r) = approved_order_filter(boardMembers(r) union directMembers(r))
```

이것은 board relation이 해당 approved member의 canonical board namespace를 건드린다는 관측 attribution이다. 개인 작성자나 법적 ownership을 주장하지 않는다. 보존된 approved vector의 per-member Q를 이용하면 되며, 새 ancestry 추정/owner registry/schema/extra ThreadId target를 만들 필요가 없다. SessionId와 ThreadId는 비교하는 domain 안에서만 사용한다. 같은 member가 mapping과 endpoint 양쪽에 걸리면 relation당 한 번이다.

| 대안 | 판정 | 반례 또는 필요한 조건 |
|---|---|---|
| 현행 Q∈M + numeric Q==M owner | 부적합 | A→X, X∉M이면 읽기 이전 거절. A→B, B→Y이면 board B를 B에 잘못 귀속. shared X board의 channel/tombstone이 같은 Q의 다른 approved member summary에서 빠진다. |
| role=root인 한 M에 모든 board relation 귀속 | 일반 대안으로 부적합 | A→X, B→Y의 board Y를 A로 돌리거나 놓친다. root label은 archive member role이고 board namespace는 Q다. root-only에 정상 삭제-effect 근거는 있지만 이를 관측 귀속 invariant로 쓰는 것은 목적 혼동이다. |
| Q 공유자를 global/전체 known mapping으로 확장 | 부적합 | unrelated known M까지 summary와 승인 scope에 들어간다. tree closure를 Q equality로 만들면 삭제 scope도 확대된다. |
| 검증된 approved M→Q matching + direct endpoint union | 조건부 권고 | complete immutable raw-source mapping, 별도 family admission, unknown gate와 실제-effect gate가 필요하다. scope/digest/profile/consumer 의미를 양쪽에서 함께 갱신·검증해야 한다. |

## relation scope와 삭제 범위

scope는 귀속 대상 수와 독립적이다. fixed reader의 `board∈targetQ`와 직접 endpoint∈approved M pair 분류를 유지한다. Q sharing을 `sharedGlobal`로 바꾸지 않는다. global이라는 새 class를 만들 필요도 없다.

| relation 사례 | scope / approved member 귀속 | subtree·삭제 판단 |
|---|---|---|
| target board, endpoint 없음(channel) | active / 해당 Q matching members | target durable collision이다. runtime cleanup 소유·효과 입증 없이는 삭제 가능성으로 전용하지 않는다. |
| target board, approved endpoint | internal / Q matching members ∪ 직접 endpoint | endpoint나 Q 공유로 subtree 확대0. 현재 exact present subtree 검사를 유지한다. |
| target board, foreign endpoint | externalOutgoing / Q matching members | 원 rollback의 foreign0 위반으로 멈춘다. board 전체 삭제가 foreign 자료를 지울 수 있다. |
| foreign board, approved endpoint | externalIncoming / 직접 endpoint만 | 원 foreign0 위반. board UUID가 approved M과 숫자로 같아도 owner 추가0. |
| target deleted_boards | passive / 해당 Q matching members | import collision에 포함. rollbackAbsent all durable0는 실패. active/foreign/unknown0와 retained 전체 조건일 때만 deletedBoard exact allowlist 후보; 삭제/RPC0. |
| 검증된 unrelated board와 foreign endpoint 또는 endpoint 없음 | target scope 없음 / 귀속 없음 | unrelated known mapping을 target으로 끌어오지 않는다. broad 지원 보존. 다만 native delete key가 그 board를 만지는지는 별도 확인한다. |
| board/endpoint parse 불가, mapping 불완전·ambiguous, owner 해석 불명 | unknown / 정상 relation으로 확정하지 않음 | false absence/foreign inference 금지. placing/delete/absence/retained 발급을 중단한다. body·AgentPath·resource UUID로 보정0. |

well-formed foreign board의 소유 M을 전부 새 registry로 만들 필요는 없다. complete approved mapping과 typed endpoint 검사로 해당 relation이 target과 무관함을 입증할 수 있는 경우는 보존한다. 반면 미검증 target mapping, full-source 불명, malformed key/불완전 scan을 단순 `b∉targetQ`로 무관하다고 숨기면 안 된다. 이 차이가 broad 지원과 unknown0를 함께 보존한다.

원 삭제 정책을 지키려면 `D={SessionId(t) | t in actual canonical delete subtree}`라는 실제 cleanup key set도 확인해야 한다(C-11~C-12). 이를 approved Q와 같다고 추정하지 않는다. 다음 두 경우가 특히 중요하다.

- targetQ\D에 active row가 있으면 native deletion 뒤 남을 수 있다. postdelete fresh proof가 nonzero를 밝혀야 하며 성공으로 숨기면 안 된다. native delete 호출의 결과를 맞추려고 Q 또는 M을 바꾸지 않는다.
- D\targetQ의 board가 존재하면 raw mapping상 unrelated board를 native caller가 삭제할 수 있다. 현재 attribution 식만으로 이 board 전체 효과를 놓칠 수 있다. 실제-effect 검사에서 차단하거나 충분한 authorized ownership 근거를 얻어야 한다. 같은 숫자 UUID를 M 또는 Q domain과 합쳐 자동 승인하면 안 된다. 행이 없어도 native cleanup이 D에 tombstone을 추가하는 effect는 별도 검증 대상이다.

이 추가 관측은 원 approved mapping/summary target을 확장하는 승인 행위가 아니다. 정상 fresh root Q=A 사례에서 root만 board를 삭제한다는 주석은 정상 cleanup 근거이지만, arbitrary Q의 안전한 삭제 지원 완료를 증명하지 않는다. passive marker all-member 경로는 delete/resume/application RPC0를 유지한다. mixed 경로는 exact fresh present subtree fixture까지 계속 차단한다.

## counts·digest·기존 suite의 의미

P `codex-rs/ext/agent-message-board/src/local/prestart_proof.rs:64-87`은 각 relation을 논리적으로 한 번 global count에 기록한다. per-member union은 같은 relation을 서로 다른 관련 member summary에 한 번씩 표시한다. shared Q 때문에 여러 member에 나타나도 새로운 DB row나 global relation이 늘어난 것이 아니다. per-member 합계를 global physical row count와 동일하게 강제하거나 shared relation을 전역에서 중복 삽입하면 안 된다. order는 original approved order, scopes/classes/null/absent shape와 bounded checked count를 유지한다.

P `codex-rs/ext/agent-message-board/src/local/prestart_proof/tests.rs:38-120`는 shared Q=root, child endpoint의 internal post를 child+root에 귀속하며 incoming은 child만 귀속한다. 이 internal case는 새 식에서도 같다. 그러나 channel, root endpoint-only post, outgoing, deletedBoard는 같은 Q의 child summary에도 들어가므로 현 root-only 숫자 귀속과 달라진다. P 같은 파일 `191-203`의 Q-outside 실패 expectation은 새 verified-mapping 조건에서는 바뀌어야 하고, 그 뒤 malformed target expectation(`204-219`)은 유지해야 한다.

P `codex-rs/ext/agent-message-board/src/local/prestart_proof/tests.rs:225-270`와 R `impl/codex/store_domain_cancel_windows_test.go:14-58`의 M\Q board는 foreign domain이고 approved endpoint에만 incoming 귀속한다는 의미는 그대로 보존된다. R `impl/codex/store_relations_windows_test.go:21-27,110-128`의 internal endpoint union·self dedup도 유지된다. 실제 test source에는 Q=X∉M shared mapping의 positive 사례나 channel/tombstone의 matching-member 전부 귀속 검증이 없다. 실행 결과로 주장하지 않는다.

새 per-member 의미는 digest/projection 비교에도 영향을 준다. immutable approval digest는 원 ordered M/parent/R/Q/source summary 그대로 두고, 바뀐 proof의 per-member counts와 global 내부 relation digest를 Go/Rust 같은 식으로 계산·검증해야 한다. 구 pin/profile의 proof를 새 의미로 조용히 재해석하거나 기존 consumer가 root-only counts를 요구하는지 확인하지 않고 호환 완료라고 보고하면 안 된다.

## 필수 fixtures와 미확정 사항

다음은 실행한 검사가 아니라 선택·구현 후 필요한 검사다.

1. fresh 정상 root A(Q=A)와 child B(Q=A)의 실제 canonical 생성, 저장 metadata, extension identity, board keys, subtree/delete를 연결한다. 공유 Q가 channel·post·subscription·optOut·tombstone 모두에서 per-member union으로 귀속되는지 확인한다.
2. 원 full source에서 A→X, B→X, X∉M; A→X,B→Y; A→B,B→Y를 검증한다. canonical parse 허용, family admission, board tool/runtime 지원, 실제 delete 결과를 서로 다른 결과로 기록한다. synthetic manifest 선언만으로 정상 생성 provenance라 하지 않는다.
3. session_id absent는 Q=M, explicit null/empty/type/invalid UUID는 reject, legacy child raw Q=M은 승인 mapping에서 parent로 보정하지 않음, copied later SessionMeta는 owning Q로 승격하지 않음, full-tail 오류는 unknown임을 검증한다.
4. target board+foreign endpoint, foreign board+approved endpoint, same numeric board/ThreadId/resource UUID, body UUID/author AgentPath, malformed endpoint/request_id/resource target를 교차 검사한다. foreign inference·ownership 보정0를 확인한다.
5. logical relation1/global count1/per-member A1+B1, same member의 mapping+endpoint dedup1, original member order, absent store zero shape, limits/overflow/frame 및 Go/Rust canonical digest 동등성을 검증한다.
6. D와 targetQ가 다른 native delete 사례에서 untouched target board, unintended unrelated board cleanup, tombstone 생성, source 변경·외부 attach·역참조를 감지해 성공·권한 발급이 차단되는지 확인한다. root+exact subtree, known unrelated, unknown owner, partial scan을 구별한다.
7. deletedBoard만 남은 경우 import collision≠absence, absent durable0, retained exact3 allowlist, all marker delete0, mixed block, postdelete/restart/source-less cleanup0engine0DB의 기존 계약을 회귀 검증한다.
8. external summary 및 최종 API consumer가 shared Q per-member counts와 marker meaning을 같은 pin/profile로 이해하는지 확인한다. fixed reader 주석상 production wiring 여부·전체 actual8 runtime/effects·fresh independent audit는 이 읽기 보고서로 완료되지 않는다.

미확정: arbitrary root M≠Q의 정상 canonical producer와 durable board 사용에 대한 end-to-end 증거, divergent parent/child Q의 실제 admission 결과, D\targetQ 효과가 현재 protected runtime gate 어디에서 포괄되는지, final API consumer의 새 count 의미 수용, exact profile/pin 및 actual8 실행 결과. 원 full source를 검증했다고 이 항목들이 자동 성립하지 않는다. 미확정 사항은 ancestry normalization 또는 새 UUID equality로 해결하지 않는다.
