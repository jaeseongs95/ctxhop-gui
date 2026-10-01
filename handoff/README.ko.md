# S4 작업 인수인계

이 브랜치는 S4 미완료 작업의 이관용 snapshot이다. 릴리스·구현 수용 PASS가 아니다.

## 소스와 복원
ctxhop-gui 기반 HEAD b4dfb268bb5a82f056efb2edc62205ed9cc85f95의 미커밋 tracked15/untracked3를 이 브랜치에 커밋했다. 기존 source checkout/index/작업 브랜치는 보존했다. 파일의 raw 바이트 목록은 source-snapshot.json에 있다.

Rust 엔진 source는 OpenAI Codex rust-v0.159.2의 실제 peeled commit ff6aec96948b70d94983af2641a6b67c94faeff5에서 출발한 feat/ctxhop-prestart HEAD d8338a5cc55db06d2255986c33b9ce06841fe0d3이다. codex-prestart-r45.bundle은 upstream base가 필요한 작은 incremental Git bundle이며 원본 인증/config/cache를 포함하지 않는다. GitHub upstream 원본에 push하지 않았다.

새 고유 작업 루트에서 복원한다. 기존 .git 없는 배포 사본에 덮어쓰지 않는다. Git clone 시 core.autocrlf=false, core.longpaths=true를 repo 로컬에 설정한다. 옛 Windows 전체 설정을 바꾸지 않는다.

```powershell
$workPath = 'D:\세션연동\ctxhop-s4-work-20261001'
New-Item -ItemType Directory -Path $workPath -ErrorAction Stop
git clone --config core.autocrlf=false --config core.longpaths=true --branch handoff/s4-20261001 https://github.com/jaeseongs95/ctxhop-gui.git (Join-Path $workPath 'ctxhop-gui')
git clone --config core.autocrlf=false --config core.longpaths=true --depth 1 --branch rust-v0.159.2 https://github.com/openai/codex.git (Join-Path $workPath 'codex-prestart-r45')
git -C (Join-Path $workPath 'codex-prestart-r45') bundle verify (Join-Path $workPath 'ctxhop-gui\handoff\codex-prestart-r45.bundle')
git -C (Join-Path $workPath 'codex-prestart-r45') fetch (Join-Path $workPath 'ctxhop-gui\handoff\codex-prestart-r45.bundle') refs/heads/feat/ctxhop-prestart:refs/heads/feat/ctxhop-prestart
git -C (Join-Path $workPath 'codex-prestart-r45') switch feat/ctxhop-prestart
```

각 명령의 exit code를 확인하고 실패하면 다음 명령을 실행하지 않는다. R의 새 이관 commit SHA는 인수인계 답변과 remote ref에서 확인한다. P HEAD는 d8338a5cc55db06d2255986c33b9ce06841fe0d3이며 clean이어야 한다. MANIFEST.json의 SHA256, overlay에서 이관한18개 파일 raw SHA와 계약 digest도 확인한다. 원본 R에서 dirty였던18개 파일은 이관 branch에서는 커밋되어 clean이다.

## 목표와 권한
S4의 폭넓은 Go 복원 지원을 위해 시작 전 설정·인증·관리정책의 실제 DB 위치, 8-store schema/typed 관계/native 획득을 증명한 다음 import/rollback/cleanup을 연결한다. 불명확한 경로를 지원으로 속이거나 기존 인증·관리정책 의미를 임의로 축소하지 않는다.
명세 검토→구현→격리 시험이 승인됐고 필요한 협업 모델은 gpt-6.1-sol/high 고정이다. 애매한 부분은 독립 토론으로 다룬다.
이번 remote push는 이관 branch에 한정한다. main 병합·PR·릴리스는 하지 않았다. 실제 사용자 홈/DB/인증정보·설치 앱·전역 설정 변경은 허용되지 않는다.

## 이관된 변경과 마지막 검증
root PS6: CodexDesktop.ps1/Worker.ps1/GUI.ps1/Strings.ps1/Test-DesktopWorker.ps1/Test-DesktopGUI.ps1. 공유 Go recovery row15 strict validation, capability 전달, fresh rollback/resolve guard와 cleanup-only GUI action, 실제 helper 시험 인자를 추가했다. UTF-8 BOM/CRLF 유지. PS7 AST6 error0와 diffcheck0만 확인됐고 PS5.1 AST/새 동작시험/완료 판정은 미실행이다. 과거1039 PASS를 현재 변경의 PASS로 인용하지 않는다.
Go tracked9/new3는 source-snapshot.json에 명시했다. Prepare9/recoveryEvidence/projection30/recoveryPlan/CREATE_NEW opaque raw copy/journal/localFinalization/CLI/same-handle native rename/cleanup-only 초안이다. 새 recovery 초안은 compile/test/vet/build0이다. syntax/import/gofmt, opaque 추가R/압축 inventory scan, full-source proof/pins, historical proof/compact manifest 재시작 결속, peak budget, alias/ancestor/close error/delete/final-save crash 행렬과 PS row null/array 해석이 미완료다.

Rust stage35:14개 중13PASS/1FAIL/1099skip, actual exit1. source_matches_canonical_fork_and_legacy_ghost_rules_without_promoting_copied_owner가 source canonical record invalid로 실패했다. future-copied-mode fixture가 정상 canonical reader에서도 유효한지 판별하고 규칙을 임의 완화하지 않는다. 이미 TRY2도 실패했다. 같은 입력 반복 실행은 하지 않는다.
history coverage exact test는 실제 PASS. native inventory는 잘못된 selector로0이며 inventory::tests::를 확인한다. strict index도 잘못된 filter로0이며 rollout_reference_index::prestart::tests::를 확인한다.
raw stage35 로그는 원본 호스트에 보존했으며 SHA256 8ffd1f9c3e633421fce3e2db94b1a1d0f2424ccf396fa57196635129b515222c다. 이 브랜치에는 test-summary.json을 넣고 개인 로컬경로가 있는 raw log/실제 DB를 게시하지 않았다.
기존 Go 3a435d4 fixture/vet/repro 완료 보고는 새 recovery 초안과 구분한다. 이전 same-private8 positive 및 actual cancellation3point 근거는 생산 엔진 full effects/runtime의 근거를 대신하지 않는다.

## 최신 계약과 안전 경계
contracts/의 s4-prestart-contract-v1.md, s4-prestart-store-set-v2.md, s4-approval-evidence-v1.md, s4-recovery-evidence-v1.md가 관련 명시 계약이다. approval SHA2132eabcc4d398c02839fefa2d8a12aab68024763892f74912001cd1d53df571, recovery SHA72290ee61d0fbccaff4f245e280c2306b6ccaec01847e68e57dfb14bcbd8bcfe. 초기 전체 rev4 draft만으로 뒤 계약을 덮지 않는다.
stores8=state/logs/goals/memories/memoriesV2/queue/threadHistory/agentMessageBoard.
M ThreadId/R immutable rollout UUID/Q board SessionId를 구분한다. body UUID나 숫자 모양의 같음을 소유권으로 승격하지 않는다. Q fallback은 key가 없는 경우만, null/empty는 거절한다. 첫 자기 SessionMeta가 owner이고 later copied fork metadata는 owner가 아니다.
원본 SQLite/ATTACH/migrate/repair/reset0, 원본SHM hash/copy0. 전체 native source PIN→전체 private완성→readonly/query_only/nonimmutable SQLite. 모든 reader close-await/nativeclose/cancel/error/panic drain.
cleanup wholeprevalidate→privatecleanup→source release→fresh 전체 PIN/hash→config/auth/rollout freshness→admission. 8-store non-atomic writer race를 완료된 atomic proof처럼 표현하지 않는다.
rollbackAbsent durable0. Retained는 state.migrationCursor/queue.revision/agentMessageBoard.deletedBoard passive3만 허용, active/foreign/unknown0. 원본 delete/activation/RPC0.
v3 자동upgrade/backfill/pin bypass0. provider/engine pins와 PENDING_REVIEW는 실제 근거 전 failclosed 유지.
recovery 첫 discovery SQL0/abort-only→Go raw durable copy+manifest+journal→firstJob0→freshsecond independently verified proof. local finalization receipt10/journal8 및 wholeprevalidate/nonrecursive owned-only cleanup. 재시작 cleanup-only engine/DB/acq/proof/applicationwrite0.
shared classifier CLI recovery-list --home / recovery-status --home --run / recovery-resolve --home --run --sha256 / finalize --home --run. list={records}, 나머지={record}; row15 required null/arrays/bools/ID/SHA/capabilities를 exact 대조한다.

## 미완료 토론·실행·감사
Board-Q: panel/에 동결 brief와 blind3 보고서가 있다. minimal4는 중단되어 보고서가 없다. root material source verification/cross/fresh judge/final record 미완료다. shared Q가 canonical 정상이고 Q∈M/equality가 불변조건이 아니라는 주장, 실제 native delete caller의 ThreadId→SessionId 키를 함께 검증해야 한다. 정책 변경을 판정 전 연결하지 않는다.
이전 effects/mapping/recovery panel record는 completed/reused lifecycle validator 모순으로 canonical FAIL이었고 승인으로 사용하지 않았다. fake lifecycle/ID 생략/plugin 수정으로 우회하지 않는다. 명시 구현 계약과 유효 panel approval은 별개다.
debug guard b4dfb26은 failed Job/termination 때 무조건 ContinueCREATE하던 결함의 수정 후보다. source/build2/pure48/Prepare12 보고가 있으나 observer/helper/debug/engine/SQLite runtime0. affected fresh independent 검토와 exact candidate/launch에 대한 별도 trusted 정확히1회 지시가 필요하다. old launch 실행 금지. ancestor race/streaming cap/hard OS deadline/종료완료 계측 미증명, capability-only이며 full effects PASS 아님.
공식 normal actual8 producer 미실행. 새 호스트 normal image/source pin, 외부 network 관측, protected Rust/provider pin, actual8 compatibility/admission/restore/retained rollback/finalization/restart/fault, required suites/repro/CI/Apache notices/최종 독립 감사가 남았다.
검사는 고정 git -c core.autocrlf=false archive의 새 사본에서만. Rust는 upstream AGENTS의 just fmt/just test/full affected suite/scoped just fix/BUILD.bazel/Apache notices를 따른다. full suite의 필요 권한은 기존 사용자 scope에 있으며 같은 승인을 다시 요구하지 않는다.
최종 high-risk 감사자는 구현자와 분리된 fresh Sol6.1/high여야 한다. 중간 토론/정적 재검토를 최종 audit PASS로 사용하지 않는다.

## 세션 생성과 협업 방식
당시 사용자 소유 H2/H3 채팅은 desktop API create_thread로 만들었고 CLI codex.exe를 별도 실행한 것이 아니다. 현재는 사용자에게 별도 새 채팅을 명시적으로 요청받은 경우에만 create_thread를 사용하고, 현재 작업의 subtask는 native collaboration을 사용한다.

별도 새 채팅의 API 예시(실행하지 않은 문서 예시):
```javascript
const projects = await tools.mcp__codex_app__list_projects({});
// 현재 컴퓨터에서 반환한 projectId/path/isGitRepository를 확인한다.
const r = await tools.mcp__codex_app__create_thread({
  target: { type: "project", projectId: "<실제 반환 ID>", environment: { type: "local" } },
  model: "gpt-6.1-sol",
  thinking: "high",
  title: "S4 담당 역할",
  prompt: "목표, 단독 파일 소유권, 제외, 계약/소스 경로와 SHA, 권한/모드, 검증, 보고서/처리 ACK"
});
```
결과 threadId/hostId를 기록하고 wait_threads({targets:[{threadId,hostId}],timeoutMs:0})로 실제 시작을 확인한다. clientThreadId는 준비 중 ID이므로 threadId를 요구하는 API에 넣지 않는다. 다음 wait는 cursor를 afterCursor로 사용한다. 기존 채팅 후속 작업은 명시 협업 권한 아래 send_message_to_thread를 사용한다. 사용자 요청 없는 새 채팅/worktree 생성0, nonGit 프로젝트 worktree0. 새 호스트에서 옛 projectId/hostId를 재사용하지 않는다.

native reviewer/subtask 예시:
```json
{"task_name":"board_q_minimal","fork_turns":"none","model":"gpt-6.1-sol","reasoning_effort":"high","message":"동결 brief/source/SHA만 읽는 blind 역할, 단독 보고서, 쓰기/실행 제외, 검증/완료 기준"}
```
collaboration.spawn_agent에 전달하며 root 포함4 slots이다. 완료 재사용 followup_task, 실행 중 알림 send_message, 중단 interrupt_agent, 상태 list_agents, 필요시 wait_agent. blind reviewer에게 root 전체 대화/타 reviewer 보고서를 주지 않는다. fresh judge도 별도 identity/context다. 모델 선택 인자와 실제 backend attestation은 구분한다.

메시지 전에 MCP list_session_status와 app wait_threads의 실제 상태를 모두 확인한다. online은 active라는 뜻이 아니다. active/online은 실행 중 주입, idle/notLoaded는 queue/wake 경로. prepare_session_message→시스템 messageId→send_session_message, 임의 mode/ID를 만들지 않는다. 불확실 전송은 같은 ID status/재시도. queued/ACK는 처리만이며 업무 완료·scope 승인이 아니다. 새 수신자에게 핵심 계약/소유권/해시/미완료를 다시 전달하고 실제 처리를 확인한다.

기존 역할: Rust/P/Cargo target 단독, Go/R impl/codex 단독, rootPS6/docs/build/catalog/통합, runner/Test-Prestart/owned-debug-probe/tooling 단독. 새 호스트에서 owner 인계를 끝내고 source를 동시에 쓰지 않는다.

