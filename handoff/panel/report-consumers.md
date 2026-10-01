# ConsumerCompatibility — 독립 blind source 검토

판정: 검증된 approved M→Q mapping을 board 측 귀속에 사용하고, 직접 typed ThreadId endpoint와 approved-plan 순서로 union하는 대안이 query scope와 per-member evidence를 가장 일관되게 만든다. 이는 구현 제안이며 제품 PASS, 삭제 승인, 실행 승인 또는 panel completion 판정이 아니다. 현재 equality 규칙은 source에서 확인되는 canonical 공유 SessionId 전체를 표현하지 못한다. 실제 삭제 caller의 M→SessionId 변환까지 자동으로 해결됐다고 볼 수 없다.

## 입력과 검토 경계

- P = `bc0e04c6f0bca377bef07e3fa0c3c6ce3784096b`, R = `3a435d471963e86201912d9abcb6b6d1c5617c18`. 아래 P/R locator는 해당 commit의 `git show` 원자료다. current worktree를 source 근거로 사용하지 않았다.
- case brief raw SHA256 = `41EBF797C7186450E8DA096BCB675C966AC724208757752C57133B2CD901D4EC`, 직접 확인했다.
- 계약 raw SHA256 세 개를 직접 확인했다: approval `2132EABCC4D398C02839FEFA2D8A12AAB68024763892F74912001CD1D53DF571`, store-set `6C4B86DF0553F3FAD03531D140E2609EC43C5DEAE24528FDD2DA76E09571F161`, recovery `72290EE61D0FBCCAFF4F245E280C2306B6CCAEC01847E68E57DFB14BCBD8BCFE`. 계약은 요구 조건이며 shipped behavior의 증명이 아니다.
- 역할은 ConsumerCompatibility. 다른 reviewer/Judge output, parent/root 대화·선호를 읽지 않았다. peer·재위임·DB·SQLite·test·engine·Cargo·trace 실행과 source 변경은 0이다. 이 보고서만 생성했다.
- 요청된 모델/effort는 gpt-6.1-sol/high다. 실제 외부 backend, effort 적용, 독립 context 구현 방식은 도구로 관측하지 못했으므로 실현 또는 격리를 입증했다고 주장하지 않는다.

## 근거에 따른 claims

**T-01 — 사실: 현재 Q mapping은 저장되지만 board 귀속에서 소실된다.** P `codex-rs/state/src/prestart_store_proof.rs:203–218,234–249,294–297`는 `PrestartApprovedMember { member_id, rollout_ids, root_session_id }`와 Q 집합을 보유한다. 이 state constructor에는 Q∈M 검사가 없다. 반면 P `codex-rs/ext/agent-message-board/src/local/prestart_proof.rs:107–114`는 Q∈M을 별도로 요구하고, `:33–37,49–62,142–147`는 M order와 Q set만 proof에 저장한 뒤 `SessionId::from(M)==board`로 귀속한다. 따라서 개별 M→Q 연결이 relation_members로 전달되지 않는다. R `impl/codex/store_relations_windows.go:12–21,41–68`는 approved slice에 ID/Root를 보존하지만 Root∈M을 요구한다. R `impl/codex/store_projection_windows.go:85–95`의 boardRoot touches도 `t.roots[board] && board==M`으로 그 연결을 쓰지 않는다.

**T-02 — 사실: 두 reader의 scope 계산은 이미 Q membership과 M endpoint membership을 구분한다.** P board proof `:127–141`와 R relations `:484–535`는 board∈approved Q / endpoint∈approved M에 따라 internal, externalOutgoing, externalIncoming, active를 정한다. deletedBoard는 Q에 해당할 때 passive다. 숫자만 같은 M인 board가 Q 밖이면 owner가 아니다. 이 부분은 proposed mapping union에서도 유지할 수 있다.

**T-03 — 사실과 추론: Q!=M·공유 Q는 canonical runtime에서 나타날 수 있다.** P `codex-rs/core/src/session/session.rs:896–915`는 재개한 첫 SessionMeta의 SessionId를 읽고, 새 non-root agent에서는 agent control identity를 사용한다. `codex-rs/core/src/agent/control/spawn.rs:709–744`는 같은 LocalAgentControl을 자식 생성에 전달한다. P `codex-rs/core/src/session/tests.rs:7112–7152`의 실제 test source는 child thread UUID와 다른 parent_session_id를 복원하도록 명시한다. P `codex-rs/ext/agent-message-board/src/extension.rs:46–64`는 session_store의 SessionId와 thread_store의 ThreadId를 따로 읽고 board identity를 session identity와 비교한다. 따라서 부모와 자식이 Q를 공유하는 정상 경로는 source로 확인된다. 임의의 A,B가 raw source 확인 없이 같은 Q를 선언하는 것까지 허용된다는 뜻은 아니다. rootA Q=X, childB Q=Y가 현재 normal 생성의 전형이라는 주장은 하지 않는다. 그 tuple의 수용 여부는 각 원자료와 ancestry/subtree 계약 확인이 필요하다.

**T-04 — 사실: raw Q를 부모/rootM으로 바꾸는 것은 canonical metadata decode가 아니다.** P `codex-rs/protocol/src/protocol.rs:3243–3268`는 session_id 키가 없을 때만 id를 넣고, 이후 SessionMeta typed decode를 수행한다. `:3130–3132`의 root-thread 설명은 decoder의 equality 검사로 구현돼 있지 않다. P `codex-rs/app-server/src/prestart_approval_reader.rs:97–114`는 실제 source의 M/parent/Q가 manifest tuple과 각각 같아야 한다. P approval `:82–92,110–119,165–206`도 session_id를 typed member field로 유지하며 Q∈M 또는 Q uniqueness를 검사하지 않는다. R `impl/codex/approval_windows.go:33–42,234–235,341–350`는 원 member의 Q를 확인하고 later copied SessionMeta를 새 ownership으로 쓰지 않는다. runtime의 legacy non-root Q=M 필터(P session `:903–907`)를 approval Q의 묵시 변경 근거로 사용할 수 없다.

**T-05 — 추론: 현재 equality는 domain collision에서 wrong-member 귀속을 만들 수 있다.** approved A→Q=B, approved B→Q=Y라고 가정하고 두 tuple이 원자료로 확인됐다면, board B의 channel/deletedBoard는 현재 P/R 규칙상 숫자가 같은 member B에 연결된다. mapping을 따라야 하는 A는 누락된다. endpoint가 A인 post는 현재 union에서 A,B로 연결될 수 있어 잘못된 B count가 추가된다. Q∈M 검사는 이 collision을 예방하지 않으며 오히려 통과시킨다. 반대로 Q=X∉M은 현재 reader/helper 단계에서 거절된다. 이것은 원자료 검증 실패와 다른 제한이다. boardRoot의 숫자를 M target으로 확장해 해결해서는 안 된다.

**T-06 — 사실: logical relation count와 per-member count는 다른 단위다.** P board proof `:64–87`는 한 observed relation을 한 번 record한다. P state proof `:149–179`는 approved-plan 순서로 affected member를 한 번씩 반환한다. R projection `:145–161`는 각 member에 대해 owner OR related가 닿으면 한 번 증가하며 relation에 matching member가 없으면 실패한다. 공유 Q union에서 하나의 channel이 A,B 두 row에 1씩 기여하는 것은 logical row를 두 번 query/record하는 것이 아니다. endpoint가 이미 Q matching member인 경우에도 그 member에 2를 더하면 안 된다. per-member 합을 logical aggregate count로 대체하면 의미가 바뀐다.

**T-07 — 사실: wire catalog는 귀속 알고리즘의 정합성을 스스로 검증하지 않는다.** R `impl/codex/store-proof-v2-catalog.json:4–26`은 approvedPlan member order, 29 classes, exact six scopes, nonnegativeExactI64를 규정한다. R `impl/codex/store_wire_windows.go:151–210`은 observationDigest, member count/order, exact classes/scopes, exact integer 및 absent slot의 zero를 검사한다. 여기에는 각 row의 Q나 relation endpoint가 없으므로 올바른 M→Q 귀속인지 재구성하지 못한다. P `codex-rs/app-server/src/prestart_store_projection.rs:5–34`도 wire에는 memberId와 counts만 넣는다. mapping provenance를 내부 provider에서 보존해야 한다.

**T-08 — 사실: digest 경계는 기존 shape와 결속을 유지해야 한다.** P `codex-rs/app-server/src/prestart_approval.rs:209–226`의 ordered mapping summary는 sessionId를 포함한다. R approval `:85–94,362–365`도 같은 summary를 사용한다. P wire `:281–295,313–348`는 approval/mapping digest와 storeProof를 projection에 넣고 projectionDigest 자기 field만 제외해 object keys를 정렬하고 array order를 보존하여 hash한다. 별도의 per-member digest field는 확인한 frozen StoreProof/member exact shape에 없다. 여기서 per-member digest 보존은 각 member row의 canonical 기여와 최종 projection digest 결속을 보존한다는 의미로 다뤄야 한다. 새 별도 digest나 catalog version이 이미 존재한다고 주장하지 않는다.

**T-09 — 사실: frozen production provider 연결은 아직 증명되지 않는다.** P `codex-rs/app-server/src/prestart_store_provider.rs:24–42`는 schema consumption 후 `storeProofProviderUnavailable`을 반환한다. R projection `:9–12`와 reader `impl/codex/store_reader_windows.go:16–19`는 callable source-only proof API이고 production complete/admission에 wired되지 않았다고 명시한다. 두 low-level 구현의 source 정합성을 검토했을 뿐 실행 중 wire provider의 end-to-end 성공을 확인하지 않았다.

**T-10 — 사실과 제약: 실제 삭제는 proof 귀속과 별개다.** P `codex-rs/core/src/thread_manager.rs:461–474`는 cleanup의 thread_ids를 `Into::into`로 boards로 바꿔 delete_boards에 전달한다. P `codex-rs/ext/agent-message-board/src/local/lifecycle.rs:20–28,67–85`는 받은 SessionId의 board 전체를 tombstone하고 posts/subscriptions/channels를 삭제하며 child ID가 parent board와 같지 않다고 설명한다. 따라서 M→Q evidence를 바로잡아도 Q!=M board의 실제 cleanup이 자동으로 따라오지 않는다. 숫자 M의 board와 approved Q가 다르면 기존 cleanup가 건드릴 수 있는 board 및 남을 Q board에 대한 별도 영향/proof gate가 필요하다. mapping relation을 deletion target approval로 승격하는 것은 금지한다.

## 대안 비교와 최소 변경

| 대안 | 소비자 결과 | 판단 |
|---|---|---|
| Q∈M + board==M 유지 | 현재 common root fixture는 유지되지만 Q∉M은 차단되고 sharedQ channel/passive/outgoing의 child row가 누락되며 collision의 잘못된 member를 선택할 수 있음 | broad canonical mapping 계약에 부적합 |
| Q∈M 검사만 제거 | scope는 읽을 수 있어도 P relation_members가 빈 집합, R projection unmatched 오류 또는 endpoint만의 부분 귀속이 됨 | 충분하지 않음 |
| ancestry로 childQ→rootM 치환 | 승인 summary와 실제 source Q를 바꾸고 distinct child board를 놓침 | 부적합 |
| verified per-member Q matching + direct typed endpoint union | scope와 attribution의 domain이 일치하고 sharedQ를 보존하며 numeric collision에도 실제 map의 M만 연결 | 조건부 권고 |

권고식은 `affected(relation) = approved-plan ordered unique { m | verifiedQ(m)==relation.board OR relation.endpoint==Some(m) }`다. board relation을 조회/record할지 정하는 Q set은 승인 member들의 verifiedQ에서만 만들고, unrelated inventory의 알려진 Q를 target set에 추가하지 않는다. endpoint 비교는 ThreadId domain에만 적용한다. post id/root와 SubscriptionTarget::Thread UUID는 resource이며 author AgentPath/body/payload/request JSON을 소유 근거로 쓰지 않는다.

최소 구현 제안은 P proof에 기존 member_order 대신 ordered `(M,typed Q)`를 retain하여 relation_members 필터만 mapping을 참조하고, R touches에 member 전체 또는 immutable member→Q 조회를 넘기는 것이다. 기존 roots set, table catalog, scopes, record-once/count bounds, M/R history 규칙은 유지한다. Q∈M 검사를 단순히 삭제한 뒤 wire 문자열을 신뢰해서는 안 된다. provider가 retained VerifiedApproval의 실제 metadata와 불변 ordered summary에서 targets를 만들고, current inventory/recovery로 원 approval을 덮어쓰지 않는 연결이 먼저 필요하다. 새 target을 만드는 bool/sourceValidated 선언은 근거가 아니다. ThreadId 타입의 root_session_id는 의미가 Q라는 사실을 분명하게 유지하고 board 비교 단계에서 SessionId를 사용한다. 타입 전면 개편이나 새 registry는 이 문제의 필수 최소 변경이 아니다.

## 요청 사례별 scope·귀속·삭제 경계

아래 A,B는 approved M이며 각 Q tuple은 별도로 verified라는 전제다. U는 approved endpoint가 아닌 typed ThreadId다. board 측 matching M들을 G(board)라고 한다.

| 입력 | logical scope | affected approved members |
|---|---|---|
| A→X, X∉M; channel board X | active | A |
| A→X,B→X; channel board X | active | A,B를 plan 순서로 각 1회 |
| A→X,B→X; post board X endpoint B | internal | A,B; B를 두 번 세지 않음 |
| A→X,B→X; post board X endpoint U | externalOutgoing | A,B; foreign fact는 그대로 유지 |
| A→X,B→Y; channel board X / Y | active | 각각 A / B; parent 관계로 union하지 않음 |
| A→X,B→Y; board X endpoint B | internal | A,B; scope는 aggregate approved set 기준 |
| A→X,B→Y; foreign board Z endpoint B | externalIncoming | B만; board owner를 B로 바꾸지 않음 |
| A→B,B→Y; channel board B | active | A만; member B 숫자와의 equality는 무관 |
| board X∈Q의 deletedBoard | passive | G(X) 전부; 원 exact retained kind만 허용 |
| canonical unrelated board Z∉Q, endpoint U∉M 또는 endpoint 없음 | target relation 없음 | 없음; 전체 parse/integrity/owner uncertainty 검사는 생략하지 않음 |
| malformed board/caller/target 또는 target과 무관함을 증명 못한 unknown owner | unknown/error | empty/foreign/absent로 성공 표시하지 않음 |

externalIncoming/Outgoing를 matching member들에게 나누어도 foreign count를 zero로 바꾸지 않는다. import collision은 passive 포함 nonzero를 막고, rollbackAbsent는 full durable0이며 rollbackRetained는 state.migrationCursor/queue.revision/agentMessageBoard.deletedBoard exact3 이외 active/foreign/unknown을 허용하지 않는다. subtree 범위는 verified M의 parent graph에서 별도로 정해야 한다. sharedQ 때문에 unrelated M을 승인하거나 board 전체 삭제를 허용하지 않는다. board 삭제의 granularity는 Q 전체이므로 approved subtree 밖의 canonical owner가 같은 Q를 사용하거나 board에 foreign endpoint가 연결돼 있으면 fresh 영향 검증 없이 진행하지 않는다. unknown owner를 scan의 scope omission과 동일하게 취급하지 않는다.

## 기존 meaningful tests의 의미와 필수 regression

1. P board tests `:38–128`의 typed endpoint/domain, incoming/outgoing, body/resource UUID 무시, query_only rejection, aggregate fixed counts는 보존한다. 기존 internal post의 `[child,root]`는 두 member가 Q를 공유하므로 새 union에서도 그대로다. 다만 기존 fixture의 root channel/outgoing/deletedBoard가 child row에도 기여하는 새 사실은 별도 assertion으로 명시해야 한다. aggregate counts를 per-member sum으로 바꾸지 않는다.
2. P `q_outside_approved_family_and_noncanonical_target_encoding_are_unknown`(`:191–222`)의 첫 assertion은 기존 Q∈M 제한을 고정하므로 verified Q∉M 지원과 그대로 공존할 수 없다. 삭제해서 coverage를 잃지 말고, raw source verified Q∉M positive fixture와 raw tuple mismatch/미검증 선언 negative fixture를 분리한다. 두 번째 unknown target encoding rejection은 그대로 남긴다. R `TestStoreApprovedMappingAndNoProductionSchemaFallback`의 outside-Q(`impl/codex/store_relations_windows_test.go:211–225`)도 같은 조건 변경을 명시하고 duplicate M/R, ambiguous history M/R, path-owner, finalize/schema gate를 보존한다.
3. P `board_uuid_in_m_but_outside_q_does_not_become_a_member_owner`(`:225–270`)와 R `TestStoreBoardRootDomainDoesNotAliasChildMember`(`impl/codex/store_domain_cancel_windows_test.go:14–61`)는 그대로 필요한 domain regression이다. M={A,B}, Q={A}에서 board B는 endpoint A에만 incoming으로 귀속하고 B member에는 zero여야 한다. 새 mapping union은 이 기대를 보존한다. 여기에 A→B,B→Y collision fixture를 더하여 board B를 A에만 귀속한다.
4. 반드시 새 sharedQ fixture에서 channel/post/subscription/optOut/deletedBoard 전 classes를 검사한다. A→X,B→X,X∉M, plan order [B,A], foreign endpoint U와 approved endpoint B, resource UUID=A, body UUID=B, AgentPath containing familiar labels를 함께 넣어 scope/count/ordered union을 확인한다. A→X,B→Y 및 board X endpoint B와 foreign board Z endpoint B의 cross-Q 방향도 확인한다.
5. R `TestStoreTypedEightReadersAndEndpointDomains`(`store_relations_windows_test.go:34–129`)의 all8 catalog, history R owner, sharedGlobal, both endpoint union, self endpoint once, absent nonzero rejection을 유지한다. 새 fixture가 기존 unrelated board semantics를 무너뜨리지 않도록 expected member-by-member zero를 명시한다. P consumed key/bounds tests와 R unknown/bounds·native drain/cancellation tests를 유지한다. Go mock rows는 Rust의 channel/post referential invariants 전체를 증명하는 실제 DB fixture가 아니다.
6. Go/Rust가 동일 ordered mapping, same relations, present mask, observation을 사용할 때 29×6 explicit counts와 member rows의 canonical bytes 및 final projectionDigest golden을 비교하는 regression이 필요하다. 공유 Q를 두 번 record하지 않음, union 중복 제거, plan reorder의 array/digest 영향, Q 교체의 approvedMappingDigest/attribution/projection 변화, 동일 object key 재배열의 canonical 안정성을 검사한다. R wire tests `store_wire_windows_test.go:191–265`의 wrong member/order/class/scope/count types/overflow/absent nonzero를 그대로 유지한다. golden JSON의 현재 generic canonical fixtures만으로 board attribution을 검증했다고 주장하지 않는다.
7. 실제 cleanup caller에 관한 새로운 regression은 원본을 건드리지 않는 canonical fixture에서 M!=Q board의 pre/post 상태, sharedQ outside-approved owner, numeric M board collision, tombstone passive 유지와 foreign/unknown가 삭제를 중단하는지 확인해야 한다. 이것은 union 변경만의 unit test로 대체할 수 없다. 원 suite의 삭제·rollback safety 의미를 보존하는 별도 수용 근거가 필요하다.

## 미확인 사항과 완료 범위

Q 공유의 canonical 생성/복원 경로는 읽은 source로 확인했다. arbitrary approved tuple의 실제 source 유효성, 전체 historical ownership closure, actual8 provider와 wire의 실제 연결, canonical subtree와 sharedQ 삭제 영향, normal engine binary/OS effects는 실행하지 않았으며 미확인이다. frozen P provider는 현재 unavailable이므로 귀속식의 source 설계만으로 제품 완료를 판정할 수 없다.

이 검토의 결론은 equality/root-only를 canonical evidence invariant로 유지할 근거가 부족하고, verified M→Q matching plus direct endpoint union이 최소한의 정합 개선이라는 조건부 설계 의견이다. unverified Q, ancestry 추정, unrelated known mapping의 target 확장, logical/per-member count 혼동 및 원 suite 축소는 허용하지 않는다. 기존 panel lifecycle/validator 상태를 변경하거나 우회하지 않았다.
