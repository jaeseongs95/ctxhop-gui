# vNext 통합 검증 기록 (2026-09-26, DESKTOP-DKTCA33)

노트북 세션의 GUI·전송 후보(`ctxhop-gui-vnext`)와 데스크톱 세션의 Codex Desktop 백엔드(`ctxhop-desktop-next`)를 합친 최종 후보입니다. 두 원본 세션은 Codex 사용량 한도로 통합 직전에 중단됐습니다.

## 통합하면서 고친 것

| 항목 | 문제 | 조치 |
|---|---|---|
| 백엔드 미포함 | `backend\` 폴더가 없고 Worker의 백엔드·Python SHA 고정값이 비어 있어 Codex 경로가 항상 중단됨 | `backend\`에 백엔드·스키마·시험 파일을 넣고 백엔드 SHA를 고정 |
| 엔진 업데이트 | 이 PC의 Codex Desktop이 17:26에 `0.158.0-alpha.2.1`로 업데이트됨. 백엔드는 `alpha.2` 문자열과 정확히 비교해 내보내기·가져오기를 모두 차단 | 실제 DB 구조를 읽기 전용으로 비교(state 마이그레이션 57개·history 7개, 객체 전부 일치) → 격리 native 시험 통과 후 `VERSIONS`에 추가. 내보낼 때 실제 엔진 버전을 기록 |
| 엔진 버전 일치 | 허용 목록만 확인하면 서로 다른 버전 PC 사이 이식이 시험 없이 허용됨(원래 계약: 버전 정확 일치) | 미리보기(`inspect`)와 복원(`apply`) 모두 백업의 엔진 버전과 이 PC 엔진 버전이 다르면 쓰기 전에 차단. 미리보기에서 "새 대화"로 보였다가 복원에서야 막히는 일이 없음 |
| 앱 종료 검사 | 종료 검사 대상 프로세스 이름에 `ChatGPT.exe`가 없음(2차 감사 지적) | 검사식에 `ChatGPT` 추가 |
| 하위 에이전트 대화 | 백엔드는 하위 에이전트 대화(`source`가 `{"subagent":…}`)를 단독으로 내보내지 않는데 목록에서는 일반 대화처럼 보여 백업을 눌러야 실패함. 이 PC 실제 대화 3,071개 중 1,506개(읽기 전용 집계) | 백엔드 `list`가 `subagent` bool을 반환하고, Worker가 해당 행을 숨기지 않고 "작업 불가: 하위 에이전트 대화는 따로 백업할 수 없습니다. 부모 대화를 선택하세요."로 표시 |
| 목록 형식 | 백엔드 `list`가 `updatedAt`을 epoch 정수(예: `1790417799`), `archived`를 `0/1`로 반환. Worker는 `archived`가 bool이 아니면 목록 전체를 실패시킴 → 실제 백엔드로는 Codex 목록이 열리지 않았음(기존 테스트는 mock이라 발견되지 않음) | 백엔드에서 UTC RFC3339 문자열과 bool로 반환 |
| 제목 줄바꿈 | 전송 메타데이터는 NUL·줄바꿈을 거부하는데 백엔드가 제목을 그대로 넘김. 이 PC 실제 대화 3,071개 중 31개가 백업 불가(독립 감사 F1, 읽기 전용 집계) | 메타데이터 제목의 `\0` `\r` `\n`을 공백으로 바꿈. 대화 내용은 그대로 |
| 오류 전달 | 백엔드는 실패 이유를 stdout JSON `reason`에 쓰는데 Worker는 `error`만 읽어 "작업 실패 (종료 코드 1)"만 표시 | Worker가 `reason`을 먼저 읽음 |
| 결과 표시 | 백엔드가 `equal`/`local_newer`로 아무것도 쓰지 않아도 "복원 완료"로 표시 | 결과별로 "복원 완료"와 "변경 없음"을 나눠 표시 |
| 실패 뒤 복구 | `apply` 실패 결과에 중단 기록 위치가 없음. 복구 중 남은 `journal.tmp`가 있으면 완료 기록이 매번 실패 | 실패 JSON에 `pending` 폴더 목록 추가, 임시 파일은 덮어씀. README에 `-HomePath`와 복구가 멈췄을 때의 수동 절차 기재 |
| 실행 정책 | 백엔드가 `powershell -ExecutionPolicy Bypass -File Assert-Closed.ps1` 호출(안정판의 "Bypass 자동 추가 금지" 계약과 충돌) | 같은 검사식을 백엔드 안의 고정 `-EncodedCommand`로 실행. 별도 스크립트 파일 삭제, 검사식은 백엔드 SHA에 포함 |
| Python 고정 | Worker가 Python 실행 파일 SHA 하나를 요구. Codex가 관리·갱신하는 런타임이고 두 PC의 사용자 경로도 달라 한 값으로 고정 불가 | Codex 번들 런타임 기본 경로 + PC별 `backend\runtime.json` 선택. PATH·자동 설치 없음. 백엔드에서 Python 3.10 미만 차단. 원래 설계와 달라 사용자에게 확인받음(수용) |
| 문서 누락(3차 감사) | 미리보기의 엔진 확인이 `tmp\arg0`에 임시 파일을 만드는데 GUI는 "읽기 전용"으로 안내. 엔진 업데이트 뒤 `recover` 차단, 갈라진 기록을 공유 백업으로 덮은 뒤 로컬 기록(`before.zip`)을 되살리는 방법이 문서에 없음 | GUI 설정 탭 문구를 "대화 파일과 DB를 바꾸지 않습니다"로 수정. README에 세 경우를 기재하고, 되살리기 절차(`inspect` → `apply`)는 `test_23`으로 CLI 경로를 확인 |
| 테스트 경로 의존 | `Test-DesktopWorker.ps1`이 형제 폴더 `..\ctxhop-gui\Worker.ps1`과 비교, mock이 백엔드에 없는 상태값 `applied` 사용 | 안정판 최종 감사 해시 `D08E9A15…`와 직접 비교, mock을 실제 값 `imported`로 |

## 전체 점검 뒤 보완 (5차 감사 이후)

| 항목 | 문제 | 조치 | 확인 |
|---|---|---|---|
| 복구 사본 엔진 표시 | `before.zip`에 실제 엔진이 아니라 지원 목록의 마지막 버전(`alpha.2.1`)이 기록돼 `alpha.2` PC에서는 로컬 기록 되살리기가 항상 차단됨(4차 감사 재현) | `apply`가 앱 종료 검사에서 얻은 이 PC 엔진 버전을 `before.zip`에 기록 | `test_24` |
| 엔진 업데이트 뒤 복구 | `recover`가 지원 엔진 목록까지 요구해, 실패 뒤 Codex가 업데이트되면 DB 구조가 같아도 복구가 막히고 그동안 모든 백업·복원이 차단됨 | `recover`는 앱 종료 검사와 고정 DB 구조 검사만 사용(이 PC의 이전 상태로 되돌리는 작업이라 엔진 버전 대신 구조로 호환 확인). 구조가 바뀌었으면 쓰기 전에 멈춤 | `test_25`(지원 밖 엔진에서 복구 성공, 구조 변경 시 차단·pending 유지) |
| 평문 사본 누적 | 백업·복원마다 평문 대화 사본이 `%LOCALAPPDATA%\CtxHopGUI\staging`에 영구히 남음 | 백업은 업로드 성공 뒤, 복원은 적용 성공 뒤 그 작업의 `staging\<GUID>` 폴더에서 알려진 파일(`session.archive`·`metadata.json`·`inspect.json`)만 지우고 빈 폴더를 삭제(재귀 삭제·링크 추적 없음). 다른 폴더·모르는 파일·링크 폴더는 건드리지 않고, 삭제 실패는 작업 실패가 아니라 결과 문구의 경고로 알림(6차 감사 F1·F2). 실패한 작업은 증거로 유지 | `Test-DesktopWorker`(연결 폴더 거부 포함, 7차 감사 N1)·`Test-DesktopIntegration` |
| 수동 복구 명령 | `backend\Invoke-Desktop.ps1`이 백엔드 SHA·`runtime.json`·Python `-I`를 쓰지 않고 `$env:CTXHOP_PYTHON`을 읽음. PowerShell 5.1의 인자 전달로 공백과 끝 `\`가 있는 경로가 깨질 수 있음 | Worker를 라이브러리로 불러 같은 고정 백엔드·Python 선택·`-I`·인자 인용(`Invoke-DesktopBackend`)을 사용. 결과는 JSON으로 출력, 실패 시 종료 코드 1. `powershell.exe -File`의 바깥 인자 경계에서 끝 `\`가 깨지는 문제는 PowerShell 자체 동작이라 README에 "끝에 `\`를 붙이지 말 것"으로 안내(6차 감사 F4) | `Test-DesktopIntegration`(변조한 백엔드 거부, PowerShell 안에서 `&`로 호출할 때 공백·끝 `\` 경로 전달) |
| 복구 중 구조 재확인 | `recover`가 쓰기 잠금 전에만 DB 구조를 확인(6차 감사 F5) | 잠금(`BEGIN IMMEDIATE`) 안에서 `check_schema`를 한 번 더 실행 | `test_26`(첫 검사와 잠금 사이 구조 변경 시 차단, 7차 감사 N2) |
| zip 경로 구분자 | `Compress-Archive`가 역슬래시 경로로 저장 | .NET `ZipFile.CreateFromDirectory`로 만들어 `/` 경로로 저장 | zip 항목 검사 |

## GitHub PR 검토 중 고친 것

| 항목 | 문제 | 조치 | 확인 |
|---|---|---|---|
| Worker 결과 파일 | GUI가 띄운 `Worker.ps1`이 `ClaudeWorker.ps1 -LibraryOnly`를 dot-source하면 ClaudeWorker의 `param` 블록이 같은 스코프의 `$RequestFile`·`$ResultFile`을 빈 값으로 다시 묶음. 요청을 읽지 못하고 결과 파일도 쓰지 못해 GUI의 모든 작업이 "작업 창이 중단되었습니다"로 끝남. 기존 시험은 Worker를 라이브러리로만 불러 이 경로를 실행하지 않았음(언어 선택 작업 중 발견) | dot-source 전에 두 경로를 보관했다가 되돌림 | `Test-DesktopWorker`가 GUI처럼 Worker를 별도 프로세스로 실행해 결과 파일을 확인. 수정 전 Worker에서는 실패 |
| macOS CI | `internal/desktopbundle`의 경로 검사가 상위 폴더의 모든 링크를 거부하는데(의도한 보안 동작), macOS 임시 폴더 `/var`가 `/private/var` 링크라 bundle 시험 11개가 실패 | 제품 검사는 그대로 두고, 시험이 링크를 푼 임시 폴더(`filepath.EvalSymlinks`)를 쓰도록 수정 | GitHub CI |

## 언어 선택 (한국어·English)

- 설정 탭에 **Language / 언어** 선택(한국어, English)을 추가했습니다. 선택은 `vnext-preferences.json`의 `language`에 저장되고 다시 시작하면 적용됩니다. 작업 요청에도 `language`가 실려 작업 창(`Worker.ps1`)의 메시지가 같은 언어로 나옵니다.
- GUI·Codex Worker·Claude Worker의 화면·오류 문장 229개를 `Strings.ps1`(`키=@('한국어','English')`)로 옮겼습니다. 한국어 문장은 원래 문자열과 같아서 기존 시험이 그대로 통과합니다.
- 번역하지 않은 것: Python 백엔드의 차단 사유, ctxhop·Codex·Claude 실행 파일 출력, 글꼴 이름과 기본 Drive 경로.
- `ClaudeWorker.ps1`은 안정판(`D08E9A15…`)과 더 이상 바이트가 같지 않습니다.
  - 바뀐 것: 문장을 `T '키'` 호출로 바꾼 것, `Strings.ps1`을 불러오는 줄, 요청의 언어를 적용하는 `Set-Language` 줄. 판단·분기 논리는 그대로입니다.
  - `Test-DesktopWorker`는 이 판의 해시를 고정합니다.
- 수동 복구 진입점 `backend\Invoke-Desktop.ps1`은 언어를 받지 않아 오류 문장이 항상 한국어입니다.
- 저장소에 있는 `gui-*-preview.png`는 이번에 다시 그리지 않아 언어 선택이 보이지 않습니다. 영어·한국어 화면은 격리 스크린샷으로 따로 확인했습니다.
- `Test-Strings.ps1`(신규)이 확인하는 것:
  - 두 언어 문장의 짝과 자리표시자
  - 세 스크립트에 남은 번역 안 된 한글(주석 제외)
  - 쓰이지 않거나 없는 키
  - 영어 화면(글자 넘침은 스크린샷으로 따로 확인)
  - 영어 선택 값으로 복원 결정
  - 별도 프로세스로 띄운 작업 창이 요청 언어로 답하는지
- 목록을 그릴 때 행마다 문장을 찾지 않도록 반복문 밖에서 한 번만 찾습니다(5,000개 첫 표시: 이번 실행들 133~187ms, 이전 기록 201ms).

## 사용성 개선 (2026-09-27)

사용자가 Codex 대화를 백업하다 목록이 계속 실패한 일을 계기로 GUI 동작을 전수 조사했습니다.

- **원인**: 작업 PC의 ctxhop 오류 기록·로그·`config.json`을 읽기만 해서 확인했습니다. 상위 폴더(`D:\codex`, `Documents\Codex`)와 하위 폴더가 서로 다른 공통 이름으로 등록된 뒤부터 그 안의 목록 불러오기와 재등록이 모두 `current directory has conflicting project bindings`로 실패했습니다.
  - 격리 폴더에서 `ctxhop 0.2.0-gui.1`로 같은 순서를 재현했습니다.
  - 상위 등록을 `project unbind`로 해제하면 다시 목록이 나오는 것을 확인했습니다.
  - 해제로 바뀌는 파일은 `config.json`뿐입니다(저장소와 registry는 그대로).
- **암호**: 격리 폴더에서 `0.2.0`·`0.2.0-gui.1`로 설정한 PC는 목록(`list`)과 Codex bundle 올리기·목록·내려받기에서 암호를 묻지 않았습니다(입력을 닫은 채 성공). 설정 중 암호 불일치나 복구 키 확인 실수는 아무것도 남기지 않아 다시 설정하면 성공합니다. 실제 문제는 실패 이유가 GUI에 보이지 않는 것이었습니다.
- **바꾼 것**:
  - 상위·하위 폴더를 다른 공통 이름으로 등록하면 ctxhop 호출 전에 막습니다(`Assert-NoBindingOverlap`). 같은 폴더를 다른 이름으로 다시 등록하는 경우는 ctxhop이 직접 거부합니다.
  - **등록 해제** 버튼(`project unbind`)을 추가했고, 등록·해제 뒤 등록된 프로젝트 목록을 다시 읽습니다. ctxhop은 `--path`의 폴더를 직접 확인하므로, 지워진 폴더는 그 공통 이름의 등록이 이 경로 하나뿐일 때만 이름(`--identity`)으로 해제합니다.
  - 등록이 하나도 없어 `config.json`에 `bindings`가 없는 PC에서도 첫 등록이 됩니다(독립 감사 F1).
  - ctxhop 명령이 실패하면 그날 ctxhop 로그에서 같은 명령의 실패 줄을 찾아 이유를 오류에 붙입니다(`Get-CtxFailureReason`). 작업 시작 시각 이후 줄만 보고, 따옴표 없이 적힌 값도 읽습니다. 다른 ctxhop이 로그를 연 채여도 공유 읽기로 읽고, 못 읽으면 종료 코드만 보입니다(F6).
  - **작업 취소**를 목록 외 작업으로 넓혔습니다. GUI가 띄운 작업 창의 프로세스 트리만 끝내며 이름으로 프로세스를 찾지 않습니다. 복원과 대화 열기는 취소할 수 없습니다.
    - 프로세스 표를 한 번만 읽어 부모부터 끝냅니다. Windows는 부모가 끝나도 `ParentProcessId`를 그대로 두고 PID를 재사용하므로, 부모보다 먼저 생긴 "자식"은 다른 프로그램으로 보고 건드리지 않습니다(F2·F4).
    - 취소 확인 창이 떠 있는 동안 작업이 끝났으면 아무것도 끝내지 않습니다(F5).
  - 설정 탭에 **암호 변경**·**복구 키로 암호 초기화**(`passphrase change`·`reset`, 보이는 작업 창)를 추가했습니다.
  - 창 크기 조절(최소 1096×675)을 추가했습니다. 화면 작업 영역보다 크면 시작할 때 줄이고, 설정 탭은 스크롤합니다. 탭 페이지는 핸들이 생겨야 실제 크기가 되므로 Anchor 전에 핸들을 만듭니다.
  - Codex 복원 확인 창: 크기 조절, 행 높이 자동, 백업 ID 별도 열, 항목 수를 표시합니다.
  - 목록: 날짜를 이 PC 시간(`yyyy-MM-dd HH:mm`)으로 표시하고, 세션 UUID가 잘리지 않게 했습니다. 여러 개를 고르면 "N개 선택"으로 표시합니다.
  - 버튼 툴팁을 추가했습니다. 꺼진 버튼은 툴팁이 뜨지 않으므로 탭과 창 위에서 대신 띄웁니다(F9).
  - 안내 문구: 실행 중인 프로그램 이름·PID, 보이는 창·숨은 창별 처리 중 문구, 설정 동기화 `[Y/n]` 기본값 Y 경고와 되돌리는 방법(실제 설정 폴더 경로로 안내), README의 "Claude 복원이 중단됐을 때" 절차.
- `Worker.ps1`, 백엔드, `bin\*.exe`는 바꾸지 않았습니다. `ClaudeWorker.ps1`의 백업·복원 판단과 복구 기록 동작은 그대로입니다.
- 시험이 다시 그리는 `gui-settings-preview.png`, `gui-desktop-conflicts-preview.png`를 새 화면으로 갱신했습니다.
- **제한**:
  - 실패 이유는 ctxhop 로그 형식(`time=… level=ERROR msg=command_finished command=… error="…"`)에 기대고, 자정을 넘긴 작업은 종료 코드만 보입니다.
  - 확인 창의 백업 ID·UUID·경로처럼 공백 없는 긴 값은 칸 안에서 잘립니다. 행을 고르면 아래 상세 칸, 칸에 마우스를 올리면 툴팁에 전체가 나옵니다.
  - 실제 125/150% 배율 화면은 확인하지 않았습니다.
  - 같은 순간 다른 ctxhop(예: hook의 `push`)이 같은 명령으로 실패하면 그 이유가 붙을 수 있습니다(F6).
  - 겹침 검사는 입력한 경로 기준입니다. ctxhop은 Git 최상위 폴더를 등록하므로, 그 아래 다른 중첩 저장소 등록과의 겹침은 GUI가 놓치고 ctxhop이 거부합니다. 데이터는 바뀌지 않습니다(F7).
  - 취소한 Codex 백업의 평문 사본은 `staging`에 남고, 공유 저장소에는 목록에 보이지 않는 chunk만 남을 수 있습니다(F8). Claude `push`를 중간에 끊었을 때의 원자성은 확인하지 않았습니다.
- **독립 감사**: 첫 감사는 FAIL(F1 빈 `bindings`에서 등록 실패, F2 PID 재사용으로 다른 프로그램 종료 가능)이었습니다. F1~F6·F9를 고치고 F7·F8은 위 제한으로 적었습니다.

## 하위 에이전트 대화 묶음 (2026-09-27)

사용자 요청: 하위 에이전트 대화는 목록에 따로 싣지 않고 부모 대화와 함께 옮깁니다. Codex Desktop과 Claude Code 모두 해당합니다. 전체 백업·프로젝트 필터 판(`20260927.2` 후보)은 공개하지 않고 이 변경과 함께 한 판으로 냅니다.

**Codex Desktop (백엔드 묶음 형식 2)**

- **목록**: `source`가 `{"subagent":…}`인 대화는 싣지 않습니다. 부모 행에는 `thread_spawn_edges`를 따라간 하위 대화 수(`children`)와 묶음에서 가장 늦은 수정 시각(`updatedAt`)을 싣습니다. 부모 대화가 없는 하위 대화는 어느 묶음에도 들지 않아 보이지 않고 백업되지 않습니다. 위 표의 "하위 에이전트 대화" 행에 적은 "작업 불가" 표시는 없앴습니다.
- **백업**: 부모 대화를 고르면 부모와 모든 하위 대화(중첩 포함), 그리고 연결(부모·자식·상태)을 한 파일에 담습니다. 파일 구성은 `manifest.json`(format 2), `data.json`(`{members, edges}`), `rollouts/NNNN.jsonl`입니다.
  - 하위 대화 ID를 직접 고르면 "부모 대화를 선택하세요"로 멈춥니다.
  - 공유 백업 메타데이터의 `historyMode` 끝에 `;family=N`을 붙여 이전 형식과 구분합니다.
  - 이전 형식(format 1, 대화 하나) 백업도 읽고 복원합니다. 목록에는 `· 이전 형식`으로 표시하고, 전체 백업에서는 최신 백업으로 치지 않습니다.
- **미리보기**: 대화별 상태(새로, 같음, 이어짐, 갈라짐, 이 PC가 더 최신, 이 PC에만)를 묶음 상태 하나로 합칩니다.
  - 하나라도 갈라지면 묶음 전체가 갈라짐입니다. 쓸 대화가 없고 이 PC가 더 최신이거나 이 PC에만 있는 하위 대화가 있으면 "이 PC가 더 최신"입니다.
  - 이유 칸에 하위 대화 상태별 개수를 붙입니다.
  - 가져올 하위 대화가 이 PC에서 다른 부모에 연결돼 있거나, 두 PC의 연결 경로가 다르면 쓰기 전에 멈춥니다.
  - 검사 토큰에 이 PC 묶음 전체의 해시가 들어갑니다. 미리보기 뒤 하위 대화가 바뀌면 다시 검사해야 합니다.
- **복원**: 새로, 이어짐, 갈라짐인 대화만 씁니다. 이 PC가 더 최신이거나 이 PC에만 있는 하위 대화는 그대로 둡니다. 연결은 새로 넣거나 상태만 바꿉니다.
- **복구 기록(version 2)**: 다음을 남깁니다.
  - `before.zip`: 이 PC 묶음 전체(format 2, 이 PC 엔진 버전 기록). 다시 가져올 수 있습니다.
  - 대화별 `incoming-NNNN.zip`과 `stage-NNNN`
  - 넣거나 바꾼 연결과 그 이전 상태
- **`recover`**: 새로 만든 대화와 연결을 지우고, 바꾼 연결은 이전 상태로, 바꾼 대화는 원래대로 되돌립니다.
  - 중단 뒤 새 대화에 다른 작업이 연결됐거나 연결 상태가 바뀌었으면 쓰기 전에 멈춥니다.
  - 이전 판이 남긴 복구 기록(version 없음, `incoming.zip`·`undo`)도 복구합니다.
- **Worker·GUI**: Worker는 목록 행의 `children`이 0 이상 정수인지 확인하고, 공유 백업은 `historyMode`의 `;family=N`에서 읽습니다. 백엔드 고정 해시도 새 값으로 바꿨습니다. GUI 맥락 칸에는 `· 하위 N`이나 `· 이전 형식`이 나옵니다.
- **백엔드 시험 8개 추가(전체 34개)**: `test_27`~`test_34`
  - 중첩 묶음 왕복과 목록
  - 이 PC가 더 최신인 하위 대화 유지
  - 갈라짐은 묶음 하나의 선택
  - 복구가 새 하위 대화와 연결을 지움
  - 중단 뒤 연결이 더해졌으면 복구 거부
  - 이전 형식 백업과 이전 복구 기록
  - 형식 검증과 다른 부모에 연결된 하위 대화
  - 가져온 하위 대화를 실제 엔진이 읽음
- **실제 데이터(이 PC `~\.codex`를 읽기 전용으로)**:
  - 최상위 대화 1,568개 중 1,532개가 묶음 검사를 통과했습니다. 하위 대화가 있는 묶음은 219개, 가장 큰 묶음은 대화 113개·239MB, 가장 느린 묶음 검사는 2.7초였습니다.
  - 실패 36개는 동적 도구 30, 경로 불일치 3, 레코드 크기 2, 1GiB 초과 1입니다. 모두 최상위 대화 자체가 이전 판에서도 막히던 경우이고, 하위 대화 때문에 새로 막힌 묶음은 없었습니다.
  - 작은 묶음 4개(중첩 연결, 닫힌 연결 포함)를 격리 폴더로 백업 → 미리보기 → 복원 → 재검사했습니다. 네 묶음 모두 대화 내용과 연결(부모·자식·상태)이 원본과 같았습니다. 재검사는 `equal`이었고, 목록에는 부모 하나와 하위 N개가 나왔고, 모든 대화의 작업 폴더가 복원 폴더로 바뀌었습니다. 격리한 실제 엔진은 가져온 대화를 모두 `thread/read`로 읽었습니다.

**Claude Code (`ctxhop 0.2.0-gui.2`)**

- `ctxhop-claude.exe`를 `0.2.0-gui.1`에서 고쳐 다시 빌드했습니다. push가 세션 옆 `<세션ID>\` 폴더를 암호화한 sidecar로 함께 올리고, 실제 resume(미리보기 제외)이 복원한 세션 파일 옆에 되돌립니다. 이 PC에만 있는 파일은 지우지 않고, 바꾸는 파일의 원본은 `--sidecar-backup` 폴더에 남깁니다. 변경, 시험, 빌드 명령은 `claude-source\PATCH-NOTES.md`에 있습니다.
  - `go test -count=1 ./...`: 시험이 있는 14개 패키지 모두 통과. `go vet ./...`: 출력 없음. `gofmt`: 바뀐 파일 없음. `TMP`·`TEMP`·`GOTMPDIR`는 `D:\Go\temp`였습니다.
  - 네 번 따로 빌드해 모두 같은 해시가 나왔습니다. 그중 한 번은 패키지에 넣은 `claude-source\`에서 빌드했습니다.
  - `claude-source\ctxhop-gui2-sidecar.patch`를 gui.1 소스에 적용하면 이 판의 Go 파일과 똑같아집니다.
- `ClaudeWorker.ps1`:
  - 복원 실행 파일의 고정 해시와 버전을 gui.2로 바꿨습니다. 버전 확인은 `0.2.0`, `0.2.0-gui.1`, `0.2.0-gui.2`를 받습니다.
  - Claude Code 복원에 `--sidecar-backup <복구 기록 이름>.companion`을 넘깁니다. 복구 기록에는 `companionBackup`, 완료 기록에는 `sidecar` 결과를 남깁니다. Codex CLI 복원에는 넘기지 않습니다.
  - 결과의 `sidecar`가 없거나 상태·개수가 틀리면 복원 완료로 기록하지 않고 pending을 남깁니다.
  - 완료 메시지에 옮긴 파일 수와 남긴 원본 수를 보여 줍니다. 이전 판 백업이라 옆 폴더가 없으면 그렇다고 알립니다.
- `Test-ClaudeWorker`: 성공, `absent`, 잘못된 결과 4종(없음·모르는 상태·음수·문자열 개수), `--sidecar-backup` 인자와 복구 기록 경로, Codex CLI 복원에는 넘기지 않는 것을 확인합니다.

**변이 검사**: 새 보호 장치를 하나씩 뺀 변이 사본 14개에서 해당 시험이 모두 실패했습니다.

- Worker 2개: 음수 하위 대화 수 통과, 이전 형식 백업을 묶음으로 봄
- GUI 4개: 이전 형식 백업을 최신으로 봄, `· 하위 N` 표시 없음, F1, F4
- ClaudeWorker 3개: 옆 폴더 결과 검사 없음, `--sidecar-backup` 없음, 이전 판 백업 안내 없음
- 백엔드 5개: 목록에 하위 대화 표시, 연결을 쓰지 않음, 이 PC가 더 최신인 하위 대화를 덮어씀, 복구가 새 연결을 남김, `before.zip`에 부모만 저장

**`20260927.2` 후보 독립 감사의 비차단 지적(F1~F5) 반영**

- F1: 원본 폴더가 비어 있는 이 PC 대화가 프로젝트 필터와 전체 백업에 들어갔습니다. 이제 로컬 행은 원본 폴더가 없으면 필터에서 빠집니다. 원본 폴더를 모르는 공유 백업은 그대로 보입니다.
- F2: 사용자가 고른 규칙에 없던 "연속 3개 실패 시 멈춤"을 시작 전 확인 창에 적었습니다.
- F3: 두 번째 취소(작업 창 즉시 종료)를 거친 전체 백업 종료 경로에 시험을 더했습니다.
- F4: 목록 다시 불러오기가 취소되거나 실패하면 전체 백업 요약을 비웁니다. 나중의 다른 목록에 요약이 나오지 않습니다.
- F5: "이 프로젝트 대화만을 끄면 …보관 대화를 봅니다"가 켠 상태에서는 보관 대화가 숨는 것처럼 읽혀, 문구를 고쳤습니다.

## 실행한 검사 (Windows PowerShell 5.1, Python 3.12.14 Codex 번들, 엔진 `0.158.0-alpha.2.1`)

| 검사 | 결과 | 원시 로그 |
|---|---|---|
| `backend\test_suite.py` (일반·위험 원본 정책 2회, 각 run마다 native probe + 단위 시험) | 각 26/26 통과, `ok: true` | `..\검증자료\suite-492977b8b2d04583aeed9be12a84659d\` |
| `Test-DesktopIntegration.ps1` (고정한 실제 백엔드. 차단 경로 + 시험 전용 진입점을 쓴 백업→전송→미리보기→복원→재검사 성공 경로, 엔진 불일치 미리보기 차단, staging 정리, 수동 진입점) | 32 assertions 통과 | `..\검증자료\ps51-r6\Test-DesktopIntegration.txt` |
| `Test-DesktopWorker.ps1` | 59 assertions 통과. Worker 결과 파일 수정 뒤 61 assertions 통과 | `..\검증자료\ps51-r6\Test-DesktopWorker.txt` (수정 뒤 실행은 PR 브랜치에서) |
| `Test-DesktopGUI.ps1` | 25 assertions 통과 | `..\검증자료\ps51-r6\Test-DesktopGUI.txt` |
| `Test-ClaudeWorker.ps1` | 37 groups, 640 assertions, 0 failures | `..\검증자료\ps51-r6\Test-ClaudeWorker.txt` |
| `Test-ClaudeGUI.ps1` | 93 assertions, 5,000개 합성 목록 첫 표시 201ms | `..\검증자료\ps51-r6\Test-ClaudeGUI.txt` |

PowerShell 시험은 `powershell.exe -NoProfile -ExecutionPolicy Bypass [-STA] -File`로 실행했고 5개 모두 종료 코드 0이었습니다(각 로그 끝에 `EXIT CODE` 기록, README의 `RemoteSigned`로는 다시 실행하지 않음).

언어 선택 뒤 같은 명령으로 6개를 다시 실행했고 모두 종료 코드 0이었습니다: `Test-Strings` 1219, `Test-DesktopWorker` 61, `Test-DesktopGUI` 25, `Test-ClaudeGUI` 93(5,000개 첫 표시 143ms), `Test-ClaudeWorker` 640 assertions, `Test-DesktopIntegration` 32. 이 실행의 원시 로그는 작업 PC의 임시 폴더에만 있습니다.

사용성 개선 뒤 같은 명령으로 6개를 다시 실행했고 모두 종료 코드 0이었습니다: `Test-Strings` 1337, `Test-DesktopWorker` 61, `Test-DesktopGUI` 26, `Test-ClaudeGUI` 113(5,000개 첫 표시 153ms), `Test-ClaudeWorker` 40 groups·655 assertions, `Test-DesktopIntegration` 32. 원시 로그는 작업 PC의 임시 폴더에만 있습니다.

감사 지적을 고친 뒤 다시 실행했고 모두 종료 코드 0이었습니다: `Test-Strings` 1342, `Test-DesktopWorker` 61, `Test-DesktopGUI` 27, `Test-ClaudeGUI` 115, `Test-ClaudeWorker` 41 groups·672 assertions, `Test-DesktopIntegration` 32.

폴더 선택 오류를 고친 뒤 6개를 `powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File`로 다시 실행했고 모두 종료 코드 0이었습니다: `Test-Strings` 1342, `Test-DesktopWorker` 61, `Test-DesktopGUI` 27, `Test-ClaudeGUI` 119, `Test-ClaudeWorker` 41 groups·672 assertions, `Test-DesktopIntegration` 32. 고친 문제는 칸이 비었거나 잘못된 문자가 든 경로에서 **폴더 선택** 세 곳과 **다른 PC용 초대 만들기**가 `LiteralPath` 또는 `Illegal characters in path` 오류를 내던 것과, 공백만 든 칸을 대화 상자의 시작 폴더로 넘기던 것입니다. 새 `Test-ClaudeGUI` 검사는 네 버튼을 빈 칸·공백·`a|b`로 눌러 보며, 이전 검사식으로 되돌린 변이 사본에서 실패합니다.

전체 백업과 프로젝트 필터를 넣은 뒤 6개를 같은 명령(`RemoteSigned`)으로 다시 실행했고 모두 종료 코드 0이었습니다: `Test-Strings` 1404, `Test-DesktopWorker` 61, `Test-DesktopGUI` 41, `Test-ClaudeGUI` 119, `Test-ClaudeWorker` 41 groups·672 assertions, `Test-DesktopIntegration` 32.
- 바꾼 파일은 `GUI.ps1`, `Strings.ps1`, `Test-DesktopGUI.ps1`, README 두 개와 이 문서입니다. Worker와 백엔드는 바꾸지 않았습니다. **필터된 대화 모두 백업**은 기존 한 대화 백업 작업을 GUI가 차례로 실행합니다.
- 새 `Test-DesktopGUI` 검사는 합성 행으로 다음을 확인합니다.
  - 프로젝트 필터: `\\?\` 접두사, 대소문자, 끝의 `\`, 하위 폴더, 이름만 비슷한 폴더(`AI논문2`), 이름만 같은 이 PC 폴더와 공유 백업의 차이, 원본 폴더를 모르는 공유 백업.
  - 전체 백업: 같은 UUID·같은 수정 시각의 공유 백업이 있는 대화와 하위 에이전트 대화를 건너뜀, 시작 전 개수 확인, 한 개씩 실행, 실패해도 계속하고 끝에 한 번 요약, 연속 3개 실패 시 멈춤, 결과 없이 끝난 작업 창을 실패 한 건으로 셈, 첫 취소는 지금 대화를 마친 뒤 멈춤, 끝난 뒤 목록 다시 불러오기.
- 위 여덟 가지 규칙을 하나씩 뺀 변이 사본 8개에서 `Test-DesktopGUI`가 모두 실패했습니다.
- 한국어·English 창을 그려 **이 프로젝트 대화만**과 **필터된 대화 모두 백업**이 잘리지 않는 것을 봤습니다. Codex Desktop에서는 늘 꺼져 있던 **선택한 대화 열기** 자리에 **필터된 대화 모두 백업**이 나옵니다.
- 실제 Codex 대화와 Drive 저장소로 전체 백업을 돌려 보지는 않았습니다. 한 대화 백업 경로는 기존 `Test-DesktopWorker`·`Test-DesktopIntegration`이 확인합니다.

하위 에이전트 대화 묶음과 F1~F5 수정을 넣은 뒤 6개를 같은 명령(`RemoteSigned`)으로 다시 실행했고 모두 종료 코드 0이었습니다: `Test-Strings` 1424, `Test-DesktopWorker` 64, `Test-DesktopGUI` 47, `Test-ClaudeGUI` 119, `Test-ClaudeWorker` 46 groups·772 assertions, `Test-DesktopIntegration` 33.
- `backend\test_suite.py`(일반·위험 원본 정책 2회, 엔진 `0.158.0-alpha.2.1`)는 각 34/34 통과, `ok: true`였습니다.
- 그 전 실행에서는 위험 원본 정책 쪽 26개가 실패했습니다. 산출물 폴더 경로가 길어 새 세션 파일 경로가 260자를 넘은 탓으로, 아래 제약의 "Python은 260자를 넘는 경로를 읽지 못합니다"와 같은 원인입니다. 짧은 폴더에서 다시 실행해 위 결과를 얻었습니다.

- 전송(`bin\ctxhop.exe`)은 PowerShell 테스트에서 mock이고, 성공 경로의 mock은 bundle 메타데이터 규칙(정확한 7개 필드, BOM 없음, NUL·줄바꿈 없음)을 확인합니다.
- `backend\test_guard_shim.py`는 시험 전용이며 앱 종료 검사와 엔진 버전 조회만 바꿉니다(엔진은 환경변수 값). Worker·GUI는 이 파일을 호출하지 않습니다. `Test-DesktopIntegration.ps1`의 성공 경로를 다른 PC에서도 다시 돌릴 수 있도록 패키지에 남겨 두었습니다.
- native 시험은 격리 `CODEX_HOME`과 localhost 고정 응답만 사용했고 외부 모델 호출은 없습니다. 검사 뒤 `%USERPROFILE%\.ctxhop`, 공유 `v1\keyfile`의 수정 시각이 이전과 같고, `%LOCALAPPDATA%\CtxHopGUI`와 임시 fixture가 남지 않은 것을 확인했습니다. PowerShell 7은 이 PC에 없어 실행하지 않았습니다.
- 이전 일곱 판(백엔드 `6AE2432C…`, 패키지 zip `04B80957…`, `6E48C2C2…`, `3ACC8589…`, `F0797242…`, `0A16B4CB…`, `8FAD77C3…`)에 대한 독립 감사는 모두 Gate PASS(차단 결함 없음)였습니다. 위 표의 제목 줄바꿈·버전 일치·복구 임시 파일·결과 표시·성공 경로 시험(1차), 미리보기 엔진 차단·`ChatGPT.exe`·하위 에이전트 표시(2차), 문서 누락(3차), 되살리기 조건·`arg0` 위치·엔진 업데이트 안내 문구(4차), staging 삭제 안전화·수동 진입점 변조 시험·끝 `\` 안내·복구 잠금 안 구조 재확인(6차), 연결 폴더 거부·잠금 안 재확인 시험(7차)은 그 감사의 비차단 발견사항을 반영한 것입니다. `F0797242…` 이후 바뀐 파일은 `backend\desktop_sessions.py`, `backend\Invoke-Desktop.ps1`, `backend\test_desktop_sessions.py`(`test_24`·`test_25`), `backend\test_guard_shim.py`, `Worker.ps1`, `Test-DesktopWorker.ps1`, `Test-DesktopIntegration.ps1`, `README.md`, `verification.md`, 그리고 시험이 다시 그리는 `gui-*-preview.png`입니다. 7차 감사(`8FAD77C3…`)와 패키지 zip 사이에는 시험 두 개(`test_26`, `Test-DesktopWorker`의 연결 폴더 거부)와 이 문서만 바뀌었고, 두 시험은 보호 장치를 뺀 변이 사본에서 실패하는 것을 확인했습니다. 그 뒤 GitHub PR에서 고친 것과 언어 선택은 위의 두 절에 있으며, 각각 별도 독립 감사에서 Gate PASS를 받았습니다.
- 사용자 결정(2026-09-26): Python 실행 파일 SHA 고정 제거를 수용, 시험 전용 `test_guard_shim.py`는 패키지에 유지.

## 설치 파일

`installer\CtxHop-GUI-vNext.iss`(Inno Setup 6.7.3)로 만듭니다. 사용자별 설치(`%LOCALAPPDATA%\Programs\CtxHop GUI vNext`, 폴더 선택 화면 없음), 64비트 Windows만, GUI 작업이 잡은 `CtxHopGUI-operation` mutex가 있으면 설치·제거를 멈춤, 실행 중인 프로그램을 닫지 않음, 바로가기와 설치 뒤 실행은 System32의 Windows PowerShell을 최소화 상태로 직접 실행합니다. 첫 판(`20260927`)이 32비트 모드였으므로 같은 모드를 유지해 덮어 설치해도 제거 기록이 하나로 남습니다.

이 PC에 실제로 설치된 판을 건드리지 않도록, 시험은 AppId와 이름만 바꾼 시험용 빌드로 했습니다(`TEST` 이름, 나머지 설정 동일). 결과:

- 첫 판 방식의 시험용 빌드 위에 새 판을 `/DIR` 없이 덮어 설치: 이전 폴더를 그대로 쓰고, 앱 목록 버전은 `2026.09.27.1`, 제거 프로그램은 `unins000` 하나, 패키지 파일 437개가 해시까지 같고, 인터넷 출처 표시(Zone.Identifier)가 없음. 사용자가 만든 `backend\runtime.json`은 유지.
- 설치된 복사본에서 시험 6개를 `RemoteSigned`로 실행해 모두 통과.
- mutex를 잡은 동안 설치와 제거는 종료 코드 1로 멈추고 파일을 바꾸지 않음. 대화형으로 실행하면 "CtxHop GUI 작업이 진행 중입니다… 작업이 끝난 뒤 확인을 누르세요" 안내 창을 띄우며, 취소하면 아무것도 바꾸지 않습니다(한국어·English 확인). GUI 창을 닫아도 작업 창(Worker)이 끝날 때까지 이 안내가 나옵니다.
- 앱 목록의 버전은 첫 판과 같은 형식(`2026.09.27.1`)입니다. Setup을 관리자 권한으로 실행하면 마지막 화면의 실행 선택지를 보이지 않게 해 GUI가 관리자 권한으로 뜨지 않게 했습니다(관리자 권한 실행 자체는 시험하지 않음).
- 제거 뒤 앱 목록 항목과 바로가기가 사라지고 설치 폴더에는 `backend\runtime.json`만 남음. 인터넷 출처 표시를 붙인 설치 파일로 새로 설치해도 설치된 파일에 표시가 없음.
- 설치 마법사(한국어·English)는 추가 작업(바탕화면 바로가기, 기본 선택) → 준비 → 완료(실행, 기본 선택) 세 화면입니다. 완료 뒤 실행한 GUI는 64비트 PowerShell에서 최소화되지 않은 창으로 떴고 콘솔 창은 보이지 않았습니다.
- 바로가기 방식 비교(Windows 11 25H2, 기본 터미널 설정 없음): `.cmd`를 여는 바로가기는 Windows Terminal 창이 잠깐 보였고, PowerShell을 최소화로 직접 여는 바로가기는 콘솔 창이 한 번도 보이지 않았습니다.
- 덮어 설치·제거 시험 전후로 `%LOCALAPPDATA%\CtxHopGUI`와 실제 설치본은 바뀌지 않았습니다. 마법사 시험에서 띄운 GUI는 시험 폴더를 `LOCALAPPDATA`로 써서 설정을 거기에 저장했습니다.

하위 에이전트 대화 묶음 판(`20260927.2`)도 같은 방식으로 시험했습니다.

- `20260927.1` 시험용 빌드 위에 덮어 설치했습니다. 이전 폴더를 그대로 썼고, 앱 목록 버전은 `2026.09.27.2`, 제거 프로그램은 `unins000` 하나였습니다. 패키지 파일 838개(`claude-source\` 401개 포함)가 해시까지 같았습니다.
- 설치된 복사본에서 시험 6개를 `RemoteSigned`로 실행해 모두 통과했습니다. mutex를 잡은 동안 설치·제거가 멈추는 것, 제거 뒤 `backend\runtime.json`만 남는 것, 인터넷 출처 표시가 없는 것도 확인했습니다.
- 설치 마법사(한국어·English)도 앞과 같이 세 화면이었고, 완료 뒤 실행한 GUI는 64비트 PowerShell에서 콘솔 창 없이 떴습니다.
- 처음 시험에서는 제거 로그가 `unins000`·`unins001` 둘로 나뉘었습니다. 이전 판으로 쓴 시험용 빌드가, 나중에 버린 초기 `.iss`(64비트 설치 모드)로 만든 옛 파일이었기 때문입니다. Inno Setup은 설치 모드(32·64비트)가 같은 로그에만 이어 씁니다. 공개된 `.1`과 같은 설정(32비트 모드)의 시험용 빌드로 다시 해 통과했습니다. 이 PC 실제 설치본의 제거 로그도 32비트 모드 헤더(`Inno Setup Uninstall Log (b)`)임을 읽기 전용으로 확인했습니다.

설치 파일은 서명이 없어 SmartScreen 경고가 뜰 수 있으며, 실제 SmartScreen 창과 다른 PC 설치는 확인하지 않았습니다.

## 고정 해시 (SHA-256)

| 파일 | SHA-256 |
|---|---|
| `backend\desktop_sessions.py` (Worker 고정, 하위 대화 묶음) | `FB1BB0160AEE8606A7D4057FE6BD2416801DAED3F85B3B48320D54FFB612DA1B` |
| `backend\Invoke-Desktop.ps1` (수동 복구 진입점) | `563FA5BD89A24D4FB12C176BF199143A76E399CFD5FBDD107DD2A5490B3A789A` |
| `backend\schema.json` (백엔드 고정) | `D24ACAC2105569B5B9CFDABC5259DB8217B9A9F175D7D2B57A09A2D4F76FA0A2` |
| `bin\ctxhop.exe` (bundle 전송, Worker 고정, 변경 없음) | `9B14CCD3B33C75EDFD9D424D76FBAF17092364C58721C1BB9C0FD6BA73C7C006` |
| `bin\ctxhop-claude.exe` (`0.2.0-gui.2`, 대화 옆 폴더, ClaudeWorker 고정) | `15CE00DC32BE07ECF089F5D49154469A4B259E1B7EB0ED0123C0FE57152BFC2B` |
| `ClaudeWorker.ps1` (안정판 `D08E9A15…`에서 문장을 `Strings.ps1`로 옮기고 언어 적용·실패 이유·겹친 등록 차단·등록 해제·암호 변경/초기화·대화 옆 폴더 복원 추가) | `2B0C34C9402B8A98AA27F0E1468F392FCDD374B60AEDB41E2D0863C4FE550E0F` |
| `Worker.ps1` (결과 파일 경로 보관 수정, 언어 선택, 하위 대화 수) | `A4C920C6C4E9500045567D4ECC9032D41742DD01E620BAF71A6189F7F6C46CAE` |
| `GUI.ps1` (언어 선택, 사용성 개선, 폴더 선택 빈 칸 오류 수정, 전체 백업, 프로젝트 필터, 하위 대화 표시) | `41598C0687E60BBA2FF961F7B1103A2103FEE49C3FFF38D1AA5CC96F13A9760B` |
| `Strings.ps1` (한국어·영어 문장 표) | `0EA6ED281CDA4A5372212AFA3DFC4C0ECE756D8364B6381AEB9E1F2B8080C8C4` |

`transport-source\`와 `bin\ctxhop.exe`는 노트북 세션 결과를 그대로 옮겼습니다. 이 둘의 Go 시험은 다시 실행하지 않았고, 기록된 결과(`transport-source\verification-results\`: 전체 suite 통과, race는 gcc 부재로 미실행)를 근거로 둡니다. `bin\ctxhop-claude.exe`는 이 PC에서 휴대용 Go 1.27.1로 빌드했고, 소스·패치·시험 로그는 `claude-source\`에 있습니다.

## 남은 제약

- **두 PC 실제 왕복 미실행**: 실제 사용자 대화의 백업→Drive→복원→앱 화면 확인은 실행하지 않았습니다. 이 PC에서 Codex 앱이 실행 중이라 실제 앱 종료 검사를 통과하는 CLI 성공 경로도 실행하지 않았고, 같은 코드는 guard를 바꾼 시험으로만 확인했습니다. 새로 가져온 세션이 Desktop 앱 사이드바에 보이는지도 확인하지 못했습니다.
- 두 PC의 Codex Desktop 엔진 버전이 같아야 가져올 수 있습니다. 첫 왕복 전에 노트북 버전을 확인하세요.
- 두 SQLite DB와 세션 파일의 원자적 갱신은 보장하지 않으며, 중단 기록과 선택 세션 원본으로 복구합니다. 복구가 멈추는 경우는 README의 수동 절차를 따릅니다(GUI 복구 화면 없음).
- 동적 도구가 등록된 세션, 알 수 없는 DB 구조, 지원하지 않는 엔진 버전은 차단합니다. 하위 에이전트 대화는 부모 대화와 한 묶음으로만 옮기며, 묶음 안의 대화 하나라도 차단 대상이면 묶음 전체를 차단합니다. 이 PC 실제 목록의 묶음 검사 결과는 위 "하위 에이전트 대화 묶음" 절에 있습니다.
- **묶음의 작업 폴더**: 복원하면 묶음의 모든 대화가 복원 때 고른 작업 폴더를 씁니다. 하위 대화가 원래 다른 폴더에서 실행됐다면 그 폴더 정보는 이 PC에 옮겨지지 않습니다.
- **Claude 대화 옆 폴더**: 파일을 그대로 복사하며 파일 안의 경로를 이 PC에 맞게 바꾸지 않습니다. 이전 판으로 만든 백업에는 옆 폴더가 없습니다. 옆 폴더는 gui.2 `push`만 올리므로, 그 뒤 다른 ctxhop(예: Claude Code hook의 자동 push)이 대화만 올렸다면 복원되는 옆 폴더는 마지막 GUI 백업 때의 내용입니다. 이때 바뀌는 이 PC 파일의 원본은 `.companion` 폴더에 남습니다.
- **두 PC 모두 새 판 필요**: 이전 판 GUI는 묶음 형식(format 2) Codex 백업을 읽지 못하고 쓰기 전에 멈춥니다. 이전 판으로 만든 백업에는 하위 대화와 Claude 옆 폴더가 없으므로, 새 판으로 다시 백업해야 함께 옮겨집니다.
- 앱 종료 검사는 프로세스 이름으로 모든 Codex 실행 파일을 막지만, 버전 확인은 `%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe` 중 최신 파일만 봅니다. 이 PC에는 `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe`(`0.155.1`, 다른 앱이 실행)도 있고 같은 `~\.codex`를 씁니다. 실행 중이면 종료 검사가 막지만, 복원 뒤 이 엔진이 가져온 대화를 열면 버전 차이의 영향은 시험하지 않았습니다.
- 가져오기 중 DB 파일이 새로 만들어지다 중단되면 `recover`가 멈출 수 있습니다. 이때는 README의 수동 절차(pending 폴더 옮기기)를 따릅니다.
- 건너뛰거나 취소한 미리보기의 staging 폴더(내려받은 평문 사본)는 자동으로 지우지 않습니다. 필요 없으면 사용자가 지웁니다.
- 2차 감사 중 실제 DB를 읽기 전용으로 읽다가 SQLite `disk I/O error`가 한 번 났고 재시도에서는 정상이었습니다. 목록이 실패하면 다시 불러오면 됩니다.
- 실행 파일(`Run-CtxHop-GUI-vNext.cmd`)과 설치 파일의 바로가기는 `-ExecutionPolicy RemoteSigned`를 씁니다. 폴더 선택 수정 뒤의 시험 6개는 이 설정으로 통과했습니다. 브라우저로 받은 zip을 그대로 풀면 인터넷 출처 표시 때문에 실행이 막힐 수 있습니다(zip 속성에서 차단 해제 후 풀기). 설치 파일로 설치한 파일에는 이 표시가 붙지 않습니다.
- `gui-*-preview.png` 스크린샷에는 이 PC 이름과 사용자 경로가 보입니다.
- Python은 260자를 넘는 경로를 읽지 못합니다(Windows 긴 경로 설정이 꺼진 경우). 아주 긴 데이터 폴더 경로에서는 가져오기가 실패하고 복구가 필요할 수 있습니다.
